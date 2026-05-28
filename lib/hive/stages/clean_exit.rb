require "open3"
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
    # Sharing `Hive::Stages::AutoCommit` means the scope-check allowlist
    # and sign-policy configured under `review.fix.auto_commit` apply
    # identically here — one knob, one place.
    module CleanExit
      module_function

      # Returns one of:
      #   { status: :clean }
      #   { status: :auto_committed, head:, paths: [...], commit_subject: }
      #   { status: :scope_violation, paths: [...], message: }
      #   { status: :git_failed, message: }
      #
      # `reason` is either :stage_exit (default) or :finalize_entry_backstop.
      # It feeds the Hive-Auto-Commit-Reason trailer so a reader scanning
      # `git log` can tell which hook produced the residue commit.
      def run!(worktree_path:, stage:, task:, cfg:, reason: :stage_exit)
        status_result = porcelain_status(worktree_path)
        return status_result unless status_result[:status] == :ok
        return { status: :clean } if status_result[:porcelain].empty?

        sign_policy = AutoCommit.auto_commit_sign_policy_for(cfg)
        sign_policy_failure = AutoCommit.auto_commit_sign_policy_failure(worktree_path, sign_policy)
        if sign_policy_failure
          return { status: :git_failed, message: sign_policy_failure[:message] }
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
            timed_out: add[:timed_out]
          )
        end

        staged = AutoCommit.staged_auto_commit_paths(worktree_path)
        unless staged[:success]
          return failure_with_unstage(worktree_path, :git_failed, message: staged[:message])
        end

        if AutoCommit.auto_commit_scope_check_enabled?(cfg)
          violations = AutoCommit.auto_commit_scope_violations(cfg, staged[:paths])
          unless violations.empty?
            return failure_with_unstage(
              worktree_path, :scope_violation,
              message: AutoCommit.auto_commit_scope_failure_message(violations),
              paths: violations.map(&:path)
            )
          end
        end

        subject = commit_subject(stage)
        message = commit_message(task: task, stage: stage, reason: reason, subject: subject)
        commit = AutoCommit.auto_commit_git_commit(worktree_path, sign_policy, message)
        unless commit[:success]
          return failure_with_unstage(worktree_path, :git_failed, message: commit[:message])
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

      # Body:
      #   <subject>
      #
      #   Hive-Task-Slug: <slug>
      #   Hive-Stage: <stage>
      #   Hive-Auto-Commit: residue
      #   Hive-Auto-Commit-Reason: <:stage_exit | :finalize_entry_backstop>
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
          [ "git", "-C", worktree_path, "status", "--porcelain" ],
          label: "git status --porcelain"
        )
        unless result[:success]
          envelope = { status: :git_failed, message: result[:message] }
          envelope[:timed_out] = true if result[:timed_out]
          return envelope
        end

        { status: :ok, porcelain: result[:stdout].to_s }
      end

      # Wrap a non-:auto_committed result in an unstage step so a failure
      # mid-commit doesn't leave the index loaded. The reset is bounded
      # by the same AUTO_COMMIT_OP_TIMEOUT_SEC cap so a hung reset
      # doesn't pin the runner. Returns a CleanExit-shaped envelope
      # (status: :scope_violation / :git_failed) so callers can
      # dispatch on a single key.
      def failure_with_unstage(worktree_path, status, message:, paths: nil, timed_out: false)
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
        envelope[:timed_out] = true if timed_out
        envelope
      end
    end
  end
end
