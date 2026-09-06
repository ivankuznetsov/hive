require "digest"
require "hive/agent_git_gate"
require "hive/patrol_fix/worktree_receipt"

module Hive
  module PatrolFix
    # One authority check for the reviewed fix worktree. Review and publication
    # intentionally run this at different points, but they must enforce the
    # same custody, HEAD, cleanliness, and diff-digest contract.
    module WorktreeSnapshot
      module_function

      def capture(task:, manifest:, fix:, validation:, worktree_root:, phase:)
        custody = Hive::PatrolFix::WorktreeReceipt.new(
          task_folder: task.folder, project_root: task.project_root,
          slug: task.slug, worktree_root: worktree_root
        )
        owner = custody.read
        custody.validate!(owner)
        unless owner.fetch("generation") == manifest.dig("task", "generation") &&
               owner.fetch("evidence_digest") == manifest.dig("evidence_revision", "digest") &&
               owner.fetch("worktree") == fix.dig("payload", "worktree") &&
               owner.fetch("branch") == fix.dig("payload", "branch") &&
               owner.fetch("base_revision") == fix.dig("payload", "base_revision")
          raise Hive::StageError, "#{phase} worktree custody is stale"
        end

        expected_fix_custody = {
          "worktree_generation" => fix.dig("task", "generation"),
          "worktree" => owner.fetch("worktree"),
          "branch" => owner.fetch("branch"),
          "base_revision" => owner.fetch("base_revision")
        }
        unless expected_fix_custody.all? { |key, value| fix.dig("payload", key) == value }
          raise Hive::StageError, "fix receipt does not bind the current worktree custody"
        end

        head = git_read!(owner.fetch("worktree"), :head_oid).strip
        expected = fix.dig("payload", "head_revision")
        unless head == expected
          message = phase.to_sym == :review ?
            "fix worktree HEAD changed after validation" :
            "reviewed worktree HEAD changed before publication"
          raise Hive::StageError, message
        end
        unless validation.dig("payload", "worktree_head") == expected
          raise Hive::StageError, "validation receipt does not bind the current fix HEAD"
        end
        unless git_read!(owner.fetch("worktree"), :status).empty?
          message = phase.to_sym == :review ?
            "fix worktree bytes changed after validation" :
            "reviewed worktree is dirty before publication"
          raise Hive::StageError, message
        end

        diff = Hive::AgentGitGate.read(
          owner.fetch("worktree"), :diff,
          base_oid: fix.dig("payload", "base_revision"), head_oid: head
        )
        unless diff.success? && !diff.overflow
          message = phase.to_sym == :review ?
            "review diff is unavailable or oversized" :
            "reviewed diff is unavailable or oversized"
          raise Hive::StageError, message
        end
        digest = Digest::SHA256.hexdigest(diff.stdout)
        unless digest == fix.dig("payload", "diff_digest")
          message = phase.to_sym == :review ?
            "fix diff changed after validation" :
            "reviewed diff changed before publication"
          raise Hive::StageError, message
        end
        review_diff = diff.stdout.dup.force_encoding(Encoding::UTF_8)
        unless review_diff.valid_encoding?
          raise Hive::StageError, "#{phase} diff is not valid UTF-8"
        end
        {
          "owner" => owner, "worktree" => owner.fetch("worktree"),
          "head_revision" => head, "diff_digest" => digest, "diff" => review_diff
        }
      rescue Hive::PatrolFix::WorktreeReceipt::InvalidWorktree => e
        raise Hive::StageError, e.message
      end

      def git_read!(path, operation)
        result = Hive::AgentGitGate.read(path, operation)
        return result.stdout if result.success?

        raise Hive::StageError, "hardened Git #{operation} failed: #{result.stderr.to_s[0, 256]}"
      end
      private_class_method :git_read!
    end
  end
end
