require "open3"
require "fileutils"
require "hive/config"
require "hive/git_ops"
require "hive/secret_patterns"
require "hive/secret_scanner"
require "hive/stages/review/guardrail_waivers"

module Hive
  module Stages
    # Shared auto-commit helpers extracted from `Hive::Stages::Review` so the
    # per-pass review fix path AND the stage-exit `CleanExit` invariant can
    # share one scope-check + sign-policy + commit primitive.
    #
    # The module is a pure callable — no instance state, no dependencies on
    # Review-local context — and every method preserves the exact return
    # shape Review consumers expect (`{ success: bool, ... }`).
    module AutoCommit
      AUTO_COMMIT_SCOPE_GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_DOTMATCH
      AutoCommitScopeViolation = Data.define(:path, :reason, :recovery_path)
      AutoCommitSafetyViolation = Data.define(:path, :reason, :recovery_path)
      AUTO_COMMIT_OP_TIMEOUT_SEC = 300
      AUTO_COMMIT_SIGNING_ERROR_PATTERNS = [
        /gpg/i,
        /pinentry/i,
        /failed to sign/i,
        /could not sign/i,
        /signing key/i,
        /ssh.*sign/i,
        /sign.*ssh/i
      ].freeze

      module_function

      def auto_commit_scope_config(cfg)
        defaults = Hive::Config::DEFAULTS.dig("review", "fix", "auto_commit", "scope_check") || {}
        override = cfg.dig("review", "fix", "auto_commit", "scope_check")
        override.is_a?(Hash) ? defaults.merge(override) : defaults
      end

      def auto_commit_scope_check_enabled?(cfg)
        auto_commit_scope_config(cfg)["enabled"] != false
      end

      def staged_auto_commit_paths(worktree_path)
        result = capture_git_with_timeout(
          [ "git", "-C", worktree_path, "diff", "--cached", "--name-only", "--no-renames", "-z" ],
          label: "git diff --cached --name-only"
        )
        return { success: false, message: result[:message], timed_out: result[:timed_out] } unless result[:success]

        { success: true, paths: result[:stdout].split("\0").reject(&:empty?) }
      end

      # Bounded `Open3.capture3` for the auto-commit / clean-exit paths.
      # `git status`, `git add -A`, `git reset HEAD --`, `git diff
      # --cached --name-only` were originally `Open3.capture3` calls
      # with no upper bound — a hung pre-commit hook or a frozen pager
      # could pin the runner indefinitely. Use the existing
      # `AUTO_COMMIT_OP_TIMEOUT_SEC = 300` cap so the slowest auto-
      # commit op matches the slowest user-visible git op the runner
      # already supports. On timeout return `timed_out: true` so
      # callers (CleanExit etc.) surface `:error reason=
      # ensure_clean_on_exit_failed`.
      #
      # Wraps `Open3.capture3` in a `Timeout.timeout` guard. When a
      # test stubs `Open3.capture3` (current_main_coverage_gap_test.rb
      # et al.), the stub fires inside the timeout block and returns
      # immediately, preserving the existing stub-based test surface.
      # The real call benefits from the bounded deadline: a hung child
      # produces `Timeout::Error`, which we translate to
      # `timed_out: true`.
      def capture_git_with_timeout(argv, label:, timeout_sec: AUTO_COMMIT_OP_TIMEOUT_SEC)
        require "timeout"
        out, err, status = Timeout.timeout(timeout_sec) { Open3.capture3(*argv) }
        if status.success?
          { success: true, timed_out: false, stdout: out.to_s, stderr: err.to_s }
        else
          {
            success: false,
            timed_out: false,
            message: git_command_message(label, out.to_s, err.to_s),
            stdout: out.to_s,
            stderr: err.to_s
          }
        end
      rescue Timeout::Error
        {
          success: false,
          timed_out: true,
          message: "#{label} timed out after #{AUTO_COMMIT_OP_TIMEOUT_SEC}s",
          stdout: "",
          stderr: ""
        }
      end

      def normalize_staged_path(path)
        normalized = path.to_s
        parts = normalized.split("/")
        return nil if normalized.empty? || normalized.start_with?("/")
        return nil if normalized.include?("\0") || normalized.include?("\\")
        return nil if parts.any? { |part| part.empty? || part == "." || part == ".." }

        normalized
      end

      # Recovery commands already pass path arguments to Git under
      # `--literal-pathspecs`. On POSIX, a backslash is a legal filename byte,
      # not a separator, so rejecting it would make an exact residue marker
      # impossible to repair. Keep the stricter staged-policy validator above
      # for allowlist matching, but admit literal backslashes here unless the
      # host platform treats them as an alternate separator.
      def normalize_recovery_path(path)
        normalized = path.to_s
        parts = normalized.split("/")
        return nil if normalized.empty? || normalized.start_with?("/")
        return nil if normalized.include?("\0")
        return nil if File::ALT_SEPARATOR && normalized.include?(File::ALT_SEPARATOR)
        return nil if parts.any? { |part| part.empty? || part == "." || part == ".." }

        normalized
      end

      def staged_path_matches_glob?(pattern, path)
        normalized_pattern = pattern.to_s.tr("\\", "/")
        return true if File.fnmatch?(normalized_pattern, path, AUTO_COMMIT_SCOPE_GLOB_FLAGS)
        return false unless normalized_pattern.end_with?("/**")

        prefix = normalized_pattern.delete_suffix("/**")
        path == prefix || path.start_with?("#{prefix}/")
      end

      def auto_commit_scope_violations(cfg, paths)
        scope = auto_commit_scope_config(cfg)
        allowed = Array(scope["allowed_paths"])
        denied = Array(scope["denied_paths"])

        paths.filter_map do |raw_path|
          path = normalize_staged_path(raw_path)
          if path.nil?
            AutoCommitScopeViolation.new(
              path: diagnostic_path(raw_path), reason: "invalid staged path",
              recovery_path: raw_path.to_s
            )
          elsif (pattern = denied.find { |glob| staged_path_matches_glob?(glob, path) })
            AutoCommitScopeViolation.new(
              path: diagnostic_path(path), reason: "matches denied path pattern #{pattern.inspect}",
              recovery_path: path
            )
          elsif allowed.none? { |glob| staged_path_matches_glob?(glob, path) }
            AutoCommitScopeViolation.new(
              path: diagnostic_path(path),
              reason: "outside review.fix.auto_commit.scope_check.allowed_paths",
              recovery_path: path
            )
          end
        end
      end

      def auto_commit_scope_failure_message(violations)
        details = violations.first(5).map { |v| "#{v.path}: #{v.reason}" }.join("; ")
        suffix = violations.size > 5 ? "; and #{violations.size - 5} more" : ""
        "auto-commit scope check failed: #{details}#{suffix}"
      end

      # Filename allowlists answer only whether a staged path belongs to the
      # feature. They do not make the staged object safe. Inspect the exact
      # index snapshot before committing so a worktree symlink cannot smuggle
      # an external target into history and newly added credential material
      # cannot pass merely because its filename is allowed.
      def auto_commit_safety_violations(worktree_path, paths, cfg: nil)
        entries = staged_index_entries(worktree_path, paths)
        return entries unless entries[:success]

        head_objects = head_blob_object_ids(worktree_path, paths)
        return head_objects unless head_objects[:success]

        violations = entries[:entries].filter_map do |entry|
          if !head_objects[:object_ids].key?(entry[:path]) && Hive::SecretScanner.match?(entry[:path])
            next AutoCommitSafetyViolation.new(
              path: diagnostic_path(entry[:path]),
              reason: "new staged path matches secret detectors",
              recovery_path: entry[:path]
            )
          end
          next if %w[100644 100755].include?(entry[:mode])

          AutoCommitSafetyViolation.new(
            path: diagnostic_path(entry[:path]),
            recovery_path: entry[:path],
            reason: if entry[:mode] == "120000"
                      "staged symlinks are not eligible for automatic commit"
                    else
                      "staged mode #{entry[:mode]} is not eligible for automatic commit"
                    end
          )
        end

        secrets = staged_secret_violations(
          worktree_path, entries[:entries], head_objects[:object_ids],
          waivers: Hive::Stages::Review::GuardrailWaivers.resolve(cfg || {})
        )
        return secrets unless secrets[:success]

        { success: true, violations: (violations + secrets[:violations]).uniq }
      end

      def staged_index_entries(worktree_path, paths)
        # Enumerate the index and exact-match in Ruby. Passing filenames back
        # to Git as pathspecs is unsafe even after path normalization: a legal
        # name such as `:(literal)foo.gemspec` changes Git's matching grammar.
        argv = [ "git", "-C", worktree_path, "ls-files", "--stage", "-z" ]
        result = capture_git_with_timeout(argv, label: "git ls-files --stage")
        return result unless result[:success]

        expected = paths.to_h { |path| [ path, true ] }
        entries = result[:stdout].split("\0").filter_map do |record|
          next if record.empty?

          metadata, path = record.split("\t", 2)
          mode, object_id, stage = metadata.to_s.split(" ", 3)
          unless path && mode&.match?(/\A\d{6}\z/) && object_id&.match?(/\A[0-9a-f]+\z/) && stage&.match?(/\A[0-3]\z/)
            return { success: false, message: "git ls-files --stage returned malformed index data" }
          end

          next unless expected.key?(path)

          { mode: mode, object_id: object_id, stage: stage, path: path }
        end
        { success: true, entries: entries }
      end

      def head_blob_object_ids(worktree_path, paths)
        result = capture_git_with_timeout(
          [ "git", "-C", worktree_path, "ls-tree", "-r", "-z", "HEAD" ],
          label: "git ls-tree HEAD"
        )
        return result unless result[:success]

        expected = paths.to_h { |path| [ path, true ] }
        object_ids = result[:stdout].split("\0").each_with_object({}) do |record, found|
          next if record.empty?

          metadata, path = record.split("\t", 2)
          mode, type, object_id = metadata.to_s.split(" ", 3)
          unless path && mode&.match?(/\A\d{6}\z/) && %w[blob commit].include?(type) && object_id&.match?(/\A[0-9a-f]+\z/)
            return { success: false, message: "git ls-tree HEAD returned malformed tree data" }
          end

          found[path] = object_id if type == "blob" && expected.key?(path)
        end
        { success: true, object_ids: object_ids }
      end

      # Scan exact index blobs, including binary content, without a size cap.
      def staged_secret_violations(worktree_path, entries, head_objects, waivers: Set.new)
        violations = Hive::SecretScanner.staged_findings(
          worktree_path, entries: entries, head_objects: head_objects
        ).reject { |hit| waivers.include?([ "secrets_pattern_match.#{hit.fetch(:name)}", hit.fetch(:sha256) ]) }.map do |hit|
          AutoCommitSafetyViolation.new(
            path: diagnostic_path(hit.fetch(:path)), recovery_path: hit.fetch(:path),
            reason: "staged content matches secret detectors: #{hit.fetch(:name)}"
          )
        end
        { success: true, violations: violations.uniq }
      rescue Hive::SecretScanner::Unavailable => e
        { success: false, message: e.message }
      end

      def diagnostic_path(path)
        Hive::SecretPatterns.redact(path.to_s)
      end

      def auto_commit_safety_failure_message(violations)
        details = violations.first(5).map { |violation| "#{violation.path}: #{violation.reason}" }.join("; ")
        suffix = violations.size > 5 ? "; and #{violations.size - 5} more" : ""
        "auto-commit safety check failed: #{details}#{suffix}"
      end

      def auto_commit_sign_policy_for(cfg)
        policy = Hive::Config.review_fix_auto_commit_sign_policy(cfg)
        return policy if Hive::Config::AUTO_COMMIT_SIGN_POLICIES.include?(policy)

        raise Hive::ConfigError,
              "review.fix.auto_commit.sign_policy must be one of " \
              "#{Hive::Config::AUTO_COMMIT_SIGN_POLICIES.inspect}; got #{policy.inspect}"
      end

      def auto_commit_sign_policy_failure(worktree_path, sign_policy)
        return nil unless sign_policy == "fail"

        signing = commit_gpgsign_enabled?(worktree_path)
        unless signing[:success]
          return {
            success: false,
            reason: "fix_auto_commit_sign_policy_failed",
            message: "auto-commit signing policy failed: #{signing[:message]}; " \
                     "fix-agent changes remain unstaged in the worktree. Commit or revert those changes manually " \
                     "before clearing REVIEW_ERROR and re-running"
          }
        end
        return nil unless signing[:enabled]

        {
          success: false,
          reason: "fix_auto_commit_sign_policy_failed",
          message: "auto-commit signing policy failed: commit.gpgsign is enabled; " \
                   "fix-agent changes remain unstaged in the worktree. Either commit/revert those changes " \
                   "manually, fix signing config, or set review.fix.auto_commit.sign_policy to inherit or bypass " \
                   "before clearing REVIEW_ERROR and re-running"
        }
      end

      def commit_gpgsign_enabled?(worktree_path)
        out, err, status = Open3.capture3(
          "git", "-C", worktree_path, "config", "--bool", "--get", "commit.gpgsign"
        )
        return { success: true, enabled: out.strip == "true" } if status.success?
        return { success: true, enabled: false } if out.to_s.empty? && err.to_s.empty?

        {
          success: false,
          message: git_command_message("git config --bool --get commit.gpgsign", out, err)
        }
      end

      def auto_commit_git_commit_argv(worktree_path, sign_policy, message)
        argv = [ "git", "-C", worktree_path ]
        argv += [ "-c", "commit.gpgsign=false" ] if sign_policy == "bypass"
        argv + [ "commit", "-m", message ]
      end

      def auto_commit_git_commit(worktree_path, sign_policy, message)
        argv = auto_commit_git_commit_argv(worktree_path, sign_policy, message)
        success, err, timed_out = Hive::GitOps.new(worktree_path).run_git_with_timeout(
          argv,
          timeout_sec: AUTO_COMMIT_OP_TIMEOUT_SEC
        )
        return { success: true } if success

        detail = if timed_out
          "git commit timed out after #{AUTO_COMMIT_OP_TIMEOUT_SEC}s; signing or commit hooks may be waiting"
        else
          git_command_message("git commit", "", err)
        end
        { success: false, message: detail, timed_out: timed_out }
      end

      def auto_commit_commit_failure_reason(sign_policy, commit)
        return "fix_auto_commit_signing_failed" if commit[:timed_out]
        return nil unless sign_policy == "inherit"
        return "fix_auto_commit_signing_failed" if auto_commit_signing_error?(commit[:message])

        nil
      end

      def auto_commit_signing_error?(message)
        AUTO_COMMIT_SIGNING_ERROR_PATTERNS.any? { |pattern| message.to_s.match?(pattern) }
      end

      def auto_commit_failure_with_unstage(worktree_path, message, **attrs)
        reset = capture_git_with_timeout(
          [ "git", "-C", worktree_path, "reset", "HEAD", "--" ],
          label: "git reset HEAD --"
        )
        unless reset[:success]
          suffix = reset[:timed_out] ? reset[:message] : git_command_message("git reset HEAD --", reset[:stdout], reset[:stderr])
          message = "#{message}; #{suffix}"
        end

        { success: false, message: message }.merge(attrs)
      end

      def git_head(worktree_path)
        out, _err, status = Open3.capture3("git", "-C", worktree_path, "rev-parse", "HEAD")
        status.success? ? out.strip : nil
      end

      def git_command_message(command, out, err)
        details = [ err, out ].map(&:to_s).reject(&:empty?).join("\n").strip
        details.empty? ? "#{command} failed" : "#{command} failed: #{details}"
      end
    end
  end
end
