require "open3"
require "base64"
require "digest"
require "json"
require "hive/events"
require "hive/managed_directory"
require "hive/stages/auto_commit"

module Hive
  module Stages
    # Stage-exit invariant: worktree-owning stages (4-execute, 6-review,
    # 8-finalize) must not leave residue. `CleanExit.run!` inspects the
    # worktree, and on residue either auto-commits (scope-check passes)
    # as `chore(<stage>): commit residual worktree changes` or surfaces a
    # scope_violation / git_failed result for the caller to mark as
    # `:error reason=ensure_clean_on_exit_failed`.
    #
    # Sharing `Hive::Stages::AutoCommit` means the sign-policy configured
    # under `review.fix.auto_commit` applies identically here. The scope
    # allowlist applies to stage-exit residue; pre-fix dirty worktree
    # snapshots are intentionally broader so review recovery can preserve
    # operator/agent residue before handing the worktree to the fix agent.
    module CleanExit
      INLINE_RESIDUE_PATHS_MAX_BYTES = 4 * 1024
      RESIDUE_PATHS_MAX_BYTES = 16 * 1024 * 1024
      RESIDUE_PATHS_FILE = ".clean-exit-residue-paths.json"

      module_function

      # Returns one of:
      #   { status: :clean }
      #   { status: :auto_committed, head:, paths: [...], commit_subject: }
      #   { status: :scope_violation, paths: [...], message: }
      #   { status: :safety_violation, paths: [...], message: }
      #   { status: :git_failed, message: }
      #
      # `reason` is :stage_exit (default), :pre_fix_dirty_worktree,
      # :execute_residue_recovery, or :finalize_entry_backstop. It feeds the
      # Hive-Auto-Commit-Reason trailer so a reader scanning
      # `git log` can tell which hook produced the residue commit.
      def run!(worktree_path:, stage:, task:, cfg:, reason: :stage_exit, subject: nil)
        status_result = porcelain_status(worktree_path)
        return status_result unless status_result[:status] == :ok
        return { status: :clean } if status_result[:porcelain].empty?

        begin
          sign_policy = AutoCommit.auto_commit_sign_policy_for(cfg)
        rescue Hive::ConfigError => error
          return {
            status: :git_failed,
            message: "invalid auto-commit config: #{error.message}",
            recovery_paths: status_result[:paths]
          }
        end
        sign_policy_failure = AutoCommit.auto_commit_sign_policy_failure(worktree_path, sign_policy)
        if sign_policy_failure
          return {
            status: :git_failed,
            message: sign_policy_failure[:message],
            recovery_paths: status_result[:paths]
          }
        end

        # `git add -A` mirrors the per-pass review path: residue routinely
        # includes new files (a wiki page the agent dropped after its last
        # commit, an extracted helper) that must land alongside tracked
        # edits. The scope check inspects the exact staged path set before
        # any commit fires.
        add = AutoCommit.capture_git_with_timeout(
          [ "git", "-C", worktree_path, "add", "-A" ],
          label: "git add -A"
        )
        unless add[:success]
          return failure_with_unstage(
            worktree_path, :git_failed,
            message: add[:message],
            timed_out: add[:timed_out],
            recovery_paths: status_result[:paths]
          )
        end

        staged = AutoCommit.staged_auto_commit_paths(worktree_path)
        unless staged[:success]
          return failure_with_unstage(
            worktree_path, :git_failed,
            message: staged[:message], recovery_paths: status_result[:paths]
          )
        end

        if scope_check_required?(cfg, reason)
          violations = AutoCommit.auto_commit_scope_violations(cfg, staged[:paths])
          unless violations.empty?
            return failure_with_unstage(
              worktree_path, :scope_violation,
              message: AutoCommit.auto_commit_scope_failure_message(violations),
              paths: violations.map(&:path),
              recovery_paths: violations.map(&:recovery_path)
            )
          end
        end

        safety = AutoCommit.auto_commit_safety_violations(worktree_path, staged[:paths])
        unless safety[:success]
          return failure_with_unstage(
            worktree_path, :git_failed,
            message: safety[:message], recovery_paths: staged[:paths]
          )
        end
        unless safety[:violations].empty?
          return failure_with_unstage(
            worktree_path, :safety_violation,
            message: AutoCommit.auto_commit_safety_failure_message(safety[:violations]),
            paths: safety[:violations].map(&:path).uniq,
            recovery_paths: safety[:violations].map(&:recovery_path).uniq
          )
        end

        subject ||= commit_subject(stage)
        message = commit_message(task: task, stage: stage, reason: reason, subject: subject)
        commit = AutoCommit.auto_commit_git_commit(worktree_path, sign_policy, message)
        unless commit[:success]
          return failure_with_unstage(
            worktree_path, :git_failed,
            message: commit[:message], recovery_paths: staged[:paths]
          )
        end

        {
          status: :auto_committed,
          head: AutoCommit.git_head(worktree_path),
          paths: staged[:paths],
          commit_subject: subject
        }
      end

      def commit_subject(stage)
        "chore(#{stage}): commit residual worktree changes"
      end

      # Canonical durable marker attributes for residue that CleanExit could
      # not commit safely. Keeping serialization here makes stage-exit and
      # pre-fix recovery agree on the reason, typed failure, and lossless path
      # encoding consumed by `hive worktree discard-residue`.
      def failure_marker_attrs(result, origin: nil, task_folder: nil)
        attrs = {
          reason: "ensure_clean_on_exit_failed",
          failure_kind: result[:status].to_s,
          detail: Hive::SecretPatterns.redact(result[:message].to_s)[0, 200]
        }
        attrs[:origin] = origin.to_s unless origin.to_s.empty?
        recovery_paths = result[:recovery_paths] || result[:paths]
        if recovery_paths
          paths = Array(recovery_paths).map(&:to_s).uniq.sort
          diagnostics = result[:paths] || paths
          display_paths = Hive::Events.clean_exit_paths(diagnostics)
          payload = JSON.generate(paths)
          digest = Digest::SHA256.hexdigest(payload)
          attrs[:residue_paths] = display_paths.join(",")[0, 200]
          attrs[:residue_paths_count] = paths.length
          attrs[:residue_paths_sha256] = digest

          encoded = Base64.strict_encode64(payload)
          redactable_path = paths.any? { |path| Hive::SecretPatterns.redact(path) != path }
          if encoded.bytesize <= INLINE_RESIDUE_PATHS_MAX_BYTES && !redactable_path
            attrs[:residue_paths_b64] = encoded
          elsif persist_residue_paths(task_folder, payload)
            attrs[:residue_paths_file] = RESIDUE_PATHS_FILE
          end
        end
        attrs
      end

      # Resolve the complete marker-owned residue set. Large path lists live
      # in a task-local, integrity-checked sidecar so the marker itself always
      # remains inside Markers::MAX_MARKER_SCAN_BYTES. If that sidecar is
      # unavailable, the current worktree can still prove it is the exact
      # recorded set through the marker's count + digest.
      def recovery_paths(attrs, task_folder:, current_paths:)
        expected_digest = attrs["residue_paths_sha256"].to_s
        expected_count = parse_residue_path_count(attrs["residue_paths_count"])

        encoded = attrs["residue_paths_b64"].to_s
        unless encoded.empty?
          return verified_residue_paths(
            JSON.parse(Base64.strict_decode64(encoded)),
            expected_digest: expected_digest,
            expected_count: expected_count,
            allow_unbound: true
          )
        end

        stored = stored_residue_paths(attrs, task_folder)
        return stored if stored

        verified_residue_paths(
          current_paths,
          expected_digest: expected_digest,
          expected_count: expected_count
        )
      rescue ArgumentError, JSON::ParserError, Hive::ConfigError
        raise Hive::WorktreeError, "residue marker contains invalid encoded paths"
      end

      def persist_residue_paths(task_folder, payload)
        return false if task_folder.to_s.empty? || payload.bytesize > RESIDUE_PATHS_MAX_BYTES

        residue_directory(task_folder).atomic_write(RESIDUE_PATHS_FILE, payload, mode: 0o600)
        true
      rescue Hive::ConfigError, SystemCallError, IOError, ArgumentError, TypeError
        false
      end
      private_class_method :persist_residue_paths

      def stored_residue_paths(attrs, task_folder)
        relative = attrs["residue_paths_file"].to_s
        return nil if relative.empty?
        raise Hive::WorktreeError, "residue marker contains an invalid path reference" unless
          relative == RESIDUE_PATHS_FILE

        begin
          payload = residue_directory(task_folder).read(
            relative, max_bytes: RESIDUE_PATHS_MAX_BYTES, missing: true
          )
          return nil unless payload

          verified_residue_paths(
            JSON.parse(payload),
            expected_digest: attrs["residue_paths_sha256"].to_s,
            expected_count: parse_residue_path_count(attrs["residue_paths_count"])
          )
        rescue JSON::ParserError, Hive::ConfigError, Hive::WorktreeError
          nil
        end
      end
      private_class_method :stored_residue_paths

      def verified_residue_paths(paths, expected_digest:, expected_count:, allow_unbound: false)
        unless paths.is_a?(Array) && paths.all? { |path| path.is_a?(String) }
          raise Hive::WorktreeError, "residue marker contains invalid encoded paths"
        end

        paths = paths.uniq.sort
        return paths if allow_unbound && expected_digest.empty? && expected_count.nil?

        payload = JSON.generate(paths)
        unless expected_count == paths.length &&
               expected_digest.match?(/\A[0-9a-f]{64}\z/) &&
               Digest::SHA256.hexdigest(payload) == expected_digest
          raise Hive::WorktreeError, "residue marker path identity does not match current residue"
        end
        paths
      end
      private_class_method :verified_residue_paths

      def parse_residue_path_count(value)
        return nil if value.to_s.empty?

        count = Integer(value, 10)
        raise ArgumentError unless count >= 0

        count
      end
      private_class_method :parse_residue_path_count

      def residue_directory(task_folder)
        Hive::ManagedDirectory.new(root: task_folder, label: "clean-exit residue paths")
      end
      private_class_method :residue_directory

      # Body:
      #   <subject>
      #
      #   Hive-Task-Slug: <slug>
      #   Hive-Stage: <stage>
      #   Hive-Auto-Commit: residue
      #   Hive-Auto-Commit-Reason: <:stage_exit | :pre_fix_dirty_worktree | :execute_residue_recovery | :finalize_entry_backstop>
      def commit_message(task:, stage:, reason:, subject: nil)
        subject ||= commit_subject(stage)
        slug = task.respond_to?(:slug) ? task.slug.to_s : ""
        <<~MSG.chomp
          #{subject}

          Hive-Task-Slug: #{slug}
          Hive-Stage: #{stage}
          Hive-Auto-Commit: residue
          Hive-Auto-Commit-Reason: #{reason}
        MSG
      end

      def porcelain_status(worktree_path)
        result = AutoCommit.capture_git_with_timeout(
          [
            "git", "-C", worktree_path, "status", "--porcelain=v1", "-z",
            "--untracked-files=all", "--no-renames"
          ],
          label: "git status --porcelain"
        )
        unless result[:success]
          envelope = { status: :git_failed, message: result[:message] }
          envelope[:timed_out] = true if result[:timed_out]
          return envelope
        end

        porcelain = result[:stdout].to_s
        paths = porcelain.split("\0").filter_map do |record|
          next if record.empty?
          unless record.bytesize >= 4 && record.getbyte(2) == 32
            return { status: :git_failed, message: "git status returned malformed porcelain data" }
          end

          record.byteslice(3..).to_s
        end
        { status: :ok, porcelain: porcelain, paths: paths }
      end

      def scope_check_required?(cfg, reason)
        return false if %i[pre_fix_dirty_worktree execute_residue_recovery].include?(reason.to_sym)

        AutoCommit.auto_commit_scope_check_enabled?(cfg)
      end

      # Wrap a non-:auto_committed result in an unstage step so a failure
      # mid-commit doesn't leave the index loaded. The reset is bounded
      # by the same AUTO_COMMIT_OP_TIMEOUT_SEC cap so a hung reset
      # doesn't pin the runner. Returns a CleanExit-shaped envelope
      # (status: :scope_violation / :safety_violation / :git_failed) so callers can
      # dispatch on a single key.
      def failure_with_unstage(worktree_path, status, message:, paths: nil,
                               recovery_paths: nil, timed_out: false)
        reset = AutoCommit.capture_git_with_timeout(
          [ "git", "-C", worktree_path, "reset", "HEAD", "--" ],
          label: "git reset HEAD --"
        )
        unless reset[:success]
          message = "#{message}; #{reset[:message]}"
          timed_out ||= reset[:timed_out]
        end

        envelope = { status: status, message: message }
        envelope[:paths] = paths if paths
        envelope[:recovery_paths] = recovery_paths if recovery_paths
        envelope[:timed_out] = true if timed_out
        envelope
      end
    end
  end
end
