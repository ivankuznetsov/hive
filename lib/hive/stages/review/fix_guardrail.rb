require "open3"
require "hive/secret_patterns"
require "hive/stages/review/fix_guardrail/patterns"

module Hive
  module Stages
    module Review
      # Post-fix diff guardrail (ADR-020).
      #
      # After Phase 4 commits in the 5-review autonomous loop, scan the
      # new commits' diff for high-risk patterns. A :tripped result
      # short-circuits the loop with REVIEW_WAITING reason=fix_guardrail
      # and writes reviews/fix-guardrail-NN.md so the user inspects
      # before the loop continues. A :clean result lets the loop
      # proceed to the next Phase 2.
      #
      # Pattern set lives in lib/hive/stages/review/fix_guardrail/patterns.rb.
      # Per-project override via review.fix.guardrail.patterns_override.
      module FixGuardrail
        Result = Data.define(:status, :matches)
        Match = Data.define(:pattern_name, :file, :line, :snippet, :severity)

        module_function

        def run!(cfg:, ctx:, base_sha:, head_sha:)
          enabled = cfg.dig("review", "fix", "guardrail", "enabled")
          return Result.new(status: :skipped, matches: []) if enabled == false

          bypass = cfg.dig("review", "fix", "guardrail", "bypass")
          return Result.new(status: :skipped, matches: []) if bypass

          return Result.new(status: :clean, matches: []) if base_sha.nil? || head_sha.nil?
          return Result.new(status: :clean, matches: []) if base_sha == head_sha

          diff = capture_diff(ctx.worktree_path, base_sha, head_sha)
          return Result.new(status: :clean, matches: []) if diff.empty?

          patterns = resolve_patterns(cfg)
          matches = scan_diff(diff, patterns)

          if matches.empty?
            Result.new(status: :clean, matches: [])
          else
            Result.new(status: :tripped, matches: matches)
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
        # `false` value disables a default pattern; a Hash value adds a
        # custom pattern (must include :regex, :severity, :targets,
        # :description).
        def resolve_patterns(cfg)
          overrides = cfg.dig("review", "fix", "guardrail", "patterns_override") || {}
          patterns = Patterns::DEFAULTS.dup

          overrides.each do |name, value|
            sym = name.to_sym
            if value == false || value == "false"
              patterns.delete(sym)
            elsif value.is_a?(Hash)
              patterns[sym] = normalize_custom_pattern(name, value)
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
            header_match = chomped.match(%r{\A--- a/(.+)\z}) ||
                           chomped.match(%r{\A\+\+\+ b/(.+)\z})
            if header_match
              path = header_match[1]
              current_file = path

              patterns.each do |name, spec|
                next unless spec[:targets] == :file_path
                next unless spec[:regex] =~ path

                matches << Match.new(
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

              matches << Match.new(
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
                  matches << Match.new(
                    pattern_name: "secrets_pattern_match.#{hit[:name]}",
                    file: current_file,
                    line: current_line,
                    snippet: hit[:snippet],
                    severity: spec[:severity]
                  )
                end
              elsif spec[:regex] && spec[:regex] =~ added
                snippet = Regexp.last_match[0]
                matches << Match.new(
                  pattern_name: name.to_s,
                  file: current_file,
                  line: current_line,
                  snippet: snippet.length > 100 ? "#{snippet[0, 100]}…" : snippet,
                  severity: spec[:severity]
                )
              end
            end

            current_line += 1 if current_line
          end

          matches
        end
      end
    end
  end
end
