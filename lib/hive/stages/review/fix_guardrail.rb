require "open3"
require "digest"
require "hive/secret_patterns"
require "hive/stages/review/fix_guardrail/patterns"

module Hive
  module Stages
    module Review
      # Post-fix diff guardrail (ADR-020).
      #
      # After Phase 4 commits in the 6-review autonomous loop, scan the
      # new commits' diff for high-risk patterns. A :tripped result
      # short-circuits the loop with REVIEW_WAITING reason=fix_guardrail
      # and writes reviews/fix-guardrail-NN.md so the user inspects
      # before the loop continues. A :clean result lets the loop
      # proceed to the next Phase 2.
      #
      # Pattern set lives in lib/hive/stages/review/fix_guardrail/patterns.rb.
      # Per-project override via review.fix.guardrail.patterns_override.
      module FixGuardrail
        Result = Data.define(:status, :matches, :waived_matches)
        Match = Data.define(
          :pattern_name, :file, :line, :snippet, :severity, :match_sha256
        )
        WAIVER_SHA256 = /\A[0-9a-f]{64}\z/.freeze
        PASSWORD_ASSIGNMENT_PREFIX = /\A.*?\b(?:[A-Za-z][A-Za-z0-9]*_)*(?:password|passwd|pwd)\b['"]?\s*[:=]\s*/i
        DYNAMIC_PASSWORD_LOOKUP = /\A
          (?=[^\r\n]*(?:\[|\())
          [A-Za-z_$][A-Za-z0-9_$]*
          (?:
            \.[A-Za-z_$][A-Za-z0-9_$]*
            | \[[^\]\r\n]+\]
            | \([^\)\r\n]*\)
          )+
        \z/x

        module_function

        def run!(cfg:, ctx:, base_sha:, head_sha:)
          enabled = cfg.dig("review", "fix", "guardrail", "enabled")
          return Result.new(status: :skipped, matches: [], waived_matches: []) if enabled == false

          return Result.new(status: :clean, matches: [], waived_matches: []) if base_sha.nil? || head_sha.nil?
          return Result.new(status: :clean, matches: [], waived_matches: []) if base_sha == head_sha

          diff = capture_diff(ctx.worktree_path, base_sha, head_sha)
          return Result.new(status: :clean, matches: [], waived_matches: []) if diff.empty?

          patterns = resolve_patterns(cfg)
          waivers = resolve_waivers(cfg)
          matches, waived = scan_diff(diff, patterns).partition do |match|
            !waivers.include?([ match.pattern_name, match.match_sha256 ])
          end

          if matches.empty?
            Result.new(status: :clean, matches: [], waived_matches: waived)
          else
            Result.new(status: :tripped, matches: matches, waived_matches: waived)
          end
        end

        # Capture the diff between two commits in the worktree. Returns
        # the raw `git diff` output (unified) so file-path scanning,
        # added-line scanning, and mode-change scanning can all share
        # one pass. `-c core.quotePath=false` so unicode paths are
        # emitted verbatim instead of as `"src/\303\251.rb"` octal-
        # escaped sequences (otherwise file_path patterns miss them).
        # On `git diff` failure, raise — we don't want to silently
        # short-circuit the guardrail to :clean and let a bad diff slip
        # through. The runner's top-level rescue maps the exception to
        # REVIEW_ERROR.
        def capture_diff(worktree_path, base, head)
          out, err, status = Open3.capture3("git", "-c", "core.quotePath=false",
                                            "-C", worktree_path,
                                            "diff", "--unified=0", "#{base}..#{head}")
          unless status.success?
            raise Hive::AgentError,
                  "git diff failed in #{worktree_path}: #{err.to_s.strip}"
          end
          out
        end

        # Apply config overrides on top of the default pattern set.
        # Strict schema (closes ce-code-review AC-7):
        #   - `false` (boolean) disables a default pattern.
        #   - Hash adds (or replaces) a custom pattern; must include
        #     `regex`.
        # Anything else (true, "false", integer, nil, …) raises
        # `Hive::ConfigError` so a typo at the YAML level fails fast at
        # `hive run` startup instead of silently no-op-ing the override.
        def resolve_patterns(cfg)
          overrides = cfg.dig("review", "fix", "guardrail", "patterns_override") || {}
          patterns = Patterns::DEFAULTS.dup

          overrides.each do |name, value|
            sym = name.to_sym
            case value
            when false
              patterns.delete(sym)
            when Hash
              patterns[sym] = normalize_custom_pattern(name, value)
            else
              raise Hive::ConfigError,
                    "review.fix.guardrail.patterns_override.#{name}: must be `false` (to disable) " \
                    "or a Hash (to add custom); got #{value.inspect}"
            end
          end

          patterns.freeze
        end

        def normalize_custom_pattern(name, raw)
          regex = raw["regex"] || raw[:regex]
          severity = (raw["severity"] || raw[:severity] || "medium").to_sym
          targets = (raw["targets"] || raw[:targets] || "code").to_sym
          description = raw["description"] || raw[:description] || "custom pattern: #{name}"

          unless regex
            raise Hive::ConfigError,
                  "review.fix.guardrail.patterns_override.#{name} must have a `regex` key when adding a custom pattern"
          end

          {
            regex: regex.is_a?(Regexp) ? regex : Regexp.new(regex.to_s),
            severity: severity,
            targets: targets,
            description: description
          }
        end

        # Waivers are exact finding fingerprints, not detector/value/path
        # allowlists. A changed pattern, path, or matched snippet therefore
        # requires a fresh auditable decision instead of inheriting a broad
        # exemption forever.
        def resolve_waivers(cfg)
          values = Array(cfg.dig("review", "fix", "guardrail", "waivers"))
          values.each_with_object({}) do |value, result|
            unless value.is_a?(Hash)
              raise Hive::ConfigError,
                    "review.fix.guardrail.waivers entries must contain pattern and sha256"
            end
            pattern = (value["pattern"] || value[:pattern]).to_s
            sha256 = (value["sha256"] || value[:sha256]).to_s.downcase
            if pattern.empty? || !WAIVER_SHA256.match?(sha256)
              raise Hive::ConfigError,
                    "review.fix.guardrail.waivers entries must contain pattern and SHA-256"
            end

            result[[ pattern, sha256 ]] = true
          end.freeze
        end

        # Walk the unified diff once, dispatching each line to whichever
        # pattern targets apply. Returns Match objects ordered by
        # appearance in the diff.
        def scan_diff(diff, patterns)
          matches = []
          current_file = nil
          current_line = nil

          diff.each_line do |line|
            chomped = line.chomp

            # Reset current_file at the start of every file pair so a
            # subsequent +++ /dev/null (deletion) doesn't carry the
            # previous file's path forward.
            if chomped.start_with?("diff --git ")
              current_file = nil
              # Don't `next` — fall through so other targets (e.g.
              # raw_diff_header for permission_change) can still match
              # on the diff-git header line.
            end

            # Track current file via BOTH "--- a/<path>" and "+++ b/<path>"
            # diff headers so deletion-vector attacks (a fix agent that
            # DELETES `.github/workflows/*.yml` — header reads `+++ /dev/null`,
            # path lives only on the `--- a/` side) trip :file_path
            # patterns just like additions and modifications do.
            # With diff.mnemonicPrefix enabled git emits c/ (commit), i/
            # (index), w/ (worktree), or o/ (object) instead of a/ and b/.
            # Accept either form so cached architecture-patrol diffs receive
            # the same file-path protections as commit-to-commit review diffs.
            header_match = chomped.match(%r{\A--- [aciow]/(.+)\z}) ||
                           chomped.match(%r{\A\+\+\+ [bciow]/(.+)\z})
            if header_match
              path = header_match[1]
              current_file = path

              patterns.each do |name, spec|
                next unless spec[:targets] == :file_path
                next unless spec[:regex] =~ path

                matches << build_match(
                  pattern_name: name.to_s,
                  file: path,
                  line: nil,
                  snippet: path,
                  severity: spec[:severity]
                )
              end
              next
            end

            # Treat `+++ /dev/null` (and `--- /dev/null`) as nil so a
            # subsequent added/removed line isn't attributed to the
            # previous file.
            if chomped == "+++ /dev/null" || chomped == "--- /dev/null"
              current_file = nil
              next
            end

            # Track new-file line numbers via @@ -X,Y +A,B @@ headers.
            if (m = chomped.match(/\A@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/))
              current_line = m[1].to_i
              next
            end

            # Mode-change line: "new mode 100755" / "old mode 100644".
            patterns.each do |name, spec|
              next unless spec[:targets] == :raw_diff_header
              next unless spec[:regex] =~ chomped

              matches << build_match(
                pattern_name: name.to_s,
                file: current_file,
                line: nil,
                snippet: chomped,
                severity: spec[:severity]
              )
            end

            # Added-line content (lines starting with "+ ", excluding
            # "+++" file-header).
            next unless chomped.start_with?("+") && !chomped.start_with?("+++")

            added = chomped[1..]

            patterns.each do |name, spec|
              next unless spec[:targets] == :code

              if name == :secrets_pattern_match
                Hive::SecretPatterns.scan(added).each do |hit|
                  next if runtime_password_lookup?(added, hit)

                  matches << build_match(
                    pattern_name: "secrets_pattern_match.#{hit[:name]}",
                    file: current_file,
                    line: current_line,
                    snippet: hit[:snippet],
                    severity: spec[:severity],
                    match_sha256: hit.fetch(:sha256)
                  )
                end
              elsif spec[:regex] && spec[:regex] =~ added
                matched = Regexp.last_match[0]
                matches << build_match(
                  pattern_name: name.to_s,
                  file: current_file,
                  line: current_line,
                  snippet: matched.length > 100 ? "#{matched[0, 100]}…" : matched,
                  severity: spec[:severity],
                  match_sha256: Digest::SHA256.hexdigest(matched)
                )
              end
            end

            current_line += 1 if current_line
          end

          matches
        end

        def runtime_password_lookup?(added_line, hit)
          return false unless hit[:name] == :password_assignment

          snippet = hit[:snippet].to_s
          rhs = snippet.sub(PASSWORD_ASSIGNMENT_PREFIX, "")
          terminated = rhs.end_with?(",", ";")
          rhs = rhs[0...-1] if terminated
          return false if rhs == snippet || !DYNAMIC_PASSWORD_LOOKUP.match?(rhs)

          return true if terminated

          offset = added_line.to_s.index(snippet)
          return false unless offset

          tail = added_line.to_s[(offset + snippet.length)..].to_s.lstrip
          tail.empty? || tail.start_with?(",", ")", "}", ";", "#")
        end

        def build_match(pattern_name:, file:, line:, snippet:, severity:,
                        match_sha256: Digest::SHA256.hexdigest(snippet.to_s))
          Match.new(pattern_name:, file:, line:, snippet:, severity:, match_sha256:)
        end
        private_class_method :runtime_password_lookup?, :build_match
      end
    end
  end
end
