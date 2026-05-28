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
        add_out, add_err, add_status = Open3.capture3("git", "-C", worktree_path, "add", "-A")
        unless add_status.success?
          return failure_with_unstage(
            worktree_path, :git_failed,
            message: AutoCommit.git_command_message("git add -A", add_out, add_err)
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
        out, err, status = Open3.capture3("git", "-C", worktree_path, "status", "--porcelain")
        unless status.success?
          return {
            status: :git_failed,
            message: AutoCommit.git_command_message("git status --porcelain", out, err)
          }
        end

        { status: :ok, porcelain: out.to_s }
      end

      # Wrap a non-:auto_committed result in an unstage step so a failure
      # mid-commit doesn't leave the index loaded. The Open3 reset mirrors
      # Hive::Stages::AutoCommit.auto_commit_failure_with_unstage but
      # returns a CleanExit-shaped envelope (status: :scope_violation /
      # :git_failed) so callers can dispatch on a single key.
      def failure_with_unstage(worktree_path, status, message:, paths: nil)
        reset_out, reset_err, reset_status = Open3.capture3(
          "git", "-C", worktree_path, "reset", "HEAD", "--"
        )
        unless reset_status.success?
          message = "#{message}; " \
                    "#{AutoCommit.git_command_message('git reset HEAD --', reset_out, reset_err)}"
        end

        envelope = { status: status, message: message }
        envelope[:paths] = paths if paths
        envelope
      end
    end
  end
end
