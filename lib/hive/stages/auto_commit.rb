require "open3"
require "fileutils"
require "hive/config"
require "hive/git_ops"
require "hive/secret_patterns"

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
      AutoCommitScopeViolation = Data.define(:path, :reason)
      AutoCommitSafetyViolation = Data.define(:path, :reason)
      AUTO_COMMIT_OP_TIMEOUT_SEC = 300
      AUTO_COMMIT_BLOB_SCAN_MAX_BYTES = 1024 * 1024
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
            AutoCommitScopeViolation.new(path: diagnostic_path(raw_path), reason: "invalid staged path")
          elsif (pattern = denied.find { |glob| staged_path_matches_glob?(glob, path) })
            AutoCommitScopeViolation.new(
              path: diagnostic_path(path), reason: "matches denied path pattern #{pattern.inspect}"
            )
          elsif allowed.none? { |glob| staged_path_matches_glob?(glob, path) }
            AutoCommitScopeViolation.new(
              path: diagnostic_path(path),
              reason: "outside review.fix.auto_commit.scope_check.allowed_paths"
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
      def auto_commit_safety_violations(worktree_path, paths)
        entries = staged_index_entries(worktree_path, paths)
        return entries unless entries[:success]

        head_objects = head_blob_object_ids(worktree_path, paths)
        return head_objects unless head_objects[:success]

        violations = entries[:entries].filter_map do |entry|
          if !head_objects[:object_ids].key?(entry[:path]) && Hive::SecretPatterns.match?(entry[:path])
            next AutoCommitSafetyViolation.new(
              path: diagnostic_path(entry[:path]),
              reason: "new staged path matches secret detectors"
            )
          end
          next if %w[100644 100755].include?(entry[:mode])

          AutoCommitSafetyViolation.new(
            path: diagnostic_path(entry[:path]),
            reason: if entry[:mode] == "120000"
                      "staged symlinks are not eligible for automatic commit"
                    else
                      "staged mode #{entry[:mode]} is not eligible for automatic commit"
                    end
          )
        end

        secrets = staged_blob_secret_violations(
          worktree_path, entries[:entries], head_objects[:object_ids]
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

      # Scan each exact staged regular-file blob. Diff-line scanning misses
      # binary blobs entirely, so the safety boundary reads the index object
      # itself and refuses oversized blobs that cannot be boundedly inspected.
      # For tracked files, subtract exact secret matches already committed at
      # HEAD so an unrelated edit does not make legacy detector fixtures
      # impossible to auto-commit. Diagnostics contain only path and detector
      # names, never blob bytes or fingerprints.
      def staged_blob_secret_violations(worktree_path, entries, head_object_ids)
        violations = entries.filter_map do |entry|
          next unless %w[100644 100755].include?(entry[:mode])

          blob = bounded_blob(worktree_path, entry[:object_id])
          return blob unless blob[:success]
          if blob[:oversized]
            next AutoCommitSafetyViolation.new(
              path: diagnostic_path(entry[:path]),
              reason: "staged blob exceeds the #{AUTO_COMMIT_BLOB_SCAN_MAX_BYTES}-byte safety scan limit"
            )
          end

          introduced = introduced_secret_names(
            worktree_path,
            Hive::SecretPatterns.scan(blob[:stdout]).map { |hit| [ hit[:name], hit[:sha256] ] },
            head_object_ids[entry[:path]]
          )
          return introduced unless introduced[:success]
          names = introduced[:names]
          next if names.empty?

          AutoCommitSafetyViolation.new(
            path: diagnostic_path(entry[:path]),
            reason: "staged content matches secret detectors: #{names.join(', ')}"
          )
        end
        { success: true, violations: violations.uniq }
      end

      def introduced_secret_names(worktree_path, staged_hits, head_object_id)
        return { success: true, names: staged_hits.map(&:first).uniq } unless head_object_id

        head_blob = bounded_blob(worktree_path, head_object_id)
        return head_blob unless head_blob[:success]
        return { success: true, names: staged_hits.map(&:first).uniq } if head_blob[:oversized]

        baseline = Hive::SecretPatterns.scan(head_blob[:stdout])
          .map { |hit| [ hit[:name], hit[:sha256] ] }.tally
        introduced = staged_hits.filter_map do |hit|
          if baseline.fetch(hit, 0).positive?
            baseline[hit] -= 1
            next
          end
          hit.first
        end
        { success: true, names: introduced.uniq }
      end

      def bounded_blob(worktree_path, object_id)
        size = capture_git_with_timeout(
          [ "git", "-C", worktree_path, "cat-file", "-s", object_id ],
          label: "git cat-file -s"
        )
        return size unless size[:success]

        bytes = Integer(size[:stdout].to_s.strip, exception: false)
        return { success: true, oversized: true } unless bytes && bytes <= AUTO_COMMIT_BLOB_SCAN_MAX_BYTES

        blob = capture_git_with_timeout(
          [ "git", "-C", worktree_path, "cat-file", "blob", object_id ],
          label: "git cat-file blob"
        )
        return blob unless blob[:success]

        { success: true, oversized: false, stdout: blob[:stdout] }
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
