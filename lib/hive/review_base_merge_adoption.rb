require "shellwords"
require "time"
require "hive/agent_git_gate"
require "hive/errors"
require "hive/git_ops"
require "hive/review_budget"
require "hive/review_publication_recovery"
require "hive/stages/review/pass_archive"
require "hive/task_activity"
require "hive/worktree"

module Hive
  # Adopts the base merge an operator makes to clear
  # `REVIEW_CI_STALE reason=base_conflict` while a review grant is active.
  # `reviews/ci-blocked.md` tells the operator to merge `origin/<base>` into
  # the task branch with a merge commit and invoke `workflow.retry`. A review
  # grant binds the exact HEAD it approved, so that merge made the grant read
  # as stale: recovery refused it (`review_grant_evidence_changed`) and
  # nothing re-ran CI or review.
  #
  # The recovery coordinator calls #adopt! under the task lock before grant
  # validation. Adoption is deliberately narrow. HEAD must be one merge
  # commit with exactly two parents. The first parent must be the head the
  # gate blocked, and the second must already be on the remote-tracking PR
  # base. The grant must validate exactly as it would have at the blocked
  # head, so the merge is the only change. Anything else (a non-merge commit,
  # a merge followed by more commits, a merge of another branch, edited
  # grant evidence) returns nil or raises, and the grant refusal stands.
  #
  # Adoption never carries the approval and never refunds budget. The review
  # generation retires as on a rewind or a remote fast-forward adoption:
  # grants expire in the audit with `expiry_reason=base_merge_adopted`, and
  # numbered passes, fix receipts and grant/completion receipts move to
  # `reviews/archive/`. The merged head then gets one fresh review from
  # pass 1 with only the configured pass budget, through the normal CI gates.
  # The retirement receipt is deterministic, so a repeated retry reuses it
  # and cannot start a second fresh review.
  class ReviewBaseMergeAdoption
    MARKER_NAME = "review_ci_stale".freeze
    MARKER_REASON = "base_conflict".freeze
    EXPIRY_REASON = "base_merge_adopted".freeze
    ACTIVITY_KEY = "adopted_base_merge".freeze
    OID = Hive::ReviewPublicationRecovery::OID
    MAX_COMMIT_BYTES = 64 * 1024

    class Refused < Hive::Error
      attr_reader :reason, :owner

      def initialize(reason, message, owner: "operator")
        @reason = reason.to_s
        @owner = owner
        super(message)
      end
    end

    def self.candidate?(marker)
      marker.name.to_s == MARKER_NAME && marker.attrs["reason"].to_s == MARKER_REASON
    end

    def initialize(task:, gate: Hive::AgentGitGate, activity: -> { Hive::TaskActivity.for_task(task) })
      @task = task
      @gate = gate
      @activity = activity
    end

    # Call only while holding the task lock. Returns nil when there is no
    # verified base merge to adopt, so the caller keeps its ordinary
    # behavior. Otherwise it returns the durable retirement receipt, also
    # when it completes an interrupted adoption.
    def adopt!(marker:)
      return nil unless self.class.candidate?(marker)

      require "hive/internal_pr_checkout"
      return nil if Hive::InternalPrCheckout.applicable?(@task)

      blocked = (Hive::ReviewPublicationRecovery.decode(marker.attrs) || {})["local_head"].to_s.downcase
      return nil unless blocked.match?(OID)

      path, base_branch = owned_worktree
      return nil unless path

      head = head_oid(path)
      return nil if head.nil? || head == blocked

      base_parent = verified_base_parent(path, base_branch, blocked, head)
      return nil unless base_parent

      receipt = { "before_oid" => blocked, "after_oid" => head,
                  "base_branch" => base_branch, "base_oid" => base_parent }
      return nil unless adoptable?(receipt)

      require_clean!(path)
      receipt = retire!(receipt)
      record!(receipt)
      receipt
    rescue Hive::AgentGitGate::Error => e
      raise Refused.new("git_unavailable", "the owned review worktree could not be read safely (#{e.message}); " \
        "inspect it with `git status --ignored` before retrying")
    end

    private

    # Only an active grant made stale by the merge alone qualifies. Once a
    # matching retirement receipt is already on disk, finish moving any
    # remaining receipts instead of revalidating a half-moved chain. Without
    # live grant receipts or a matching retirement, do nothing: retiring an
    # ungranted generation would hand out a fresh pass budget that nothing
    # authorized.
    def adoptable?(receipt)
      budget = Hive::ReviewBudget.new(task: @task, project: @task.project_name)
      present = budget.present?
      return true if Hive::Stages::Review::PassArchive.existing_retirement(@task.folder, retirement_document(receipt))
      return false unless present
      return false if grant_valid?(budget)

      # Raises ReviewBudget::Refused when anything besides HEAD changed.
      Hive::ReviewBudget.new(task: @task, project: @task.project_name, head: receipt.fetch("before_oid")).validate_resume!
      true
    end

    def grant_valid?(budget)
      budget.validate_resume!
      true
    rescue Hive::ReviewBudget::Refused
      false
    end

    def owned_worktree
      pointer = Hive::Worktree.read_owned_pointer(
        @task.folder, project_root: @task.project_root, slug: @task.slug,
        expected_root: Hive::Worktree.canonical_root(@task.project_root)
      )
      # Older pointers predate `base_branch`; fall back only to a base that
      # origin itself names, never to whatever branch a checkout is on.
      base = pointer["base_branch"].to_s
      base = Hive::GitOps.new(@task.project_root).origin_default_branch.to_s if base.empty?
      return nil if base.empty?

      [ pointer.fetch("path"), Hive::Worktree.validate_branch_name!(base) ]
    rescue Hive::WorktreeError, Hive::GitError, KeyError, SystemCallError
      nil
    end

    def head_oid(path)
      result = @gate.read(path, :head_oid)
      result.success? ? result.stdout.strip.downcase : nil
    end

    # The documented recovery is `git merge --no-ff origin/<base>` on the
    # blocked head: HEAD's first parent is that head, and its second parent
    # is already on the remote-tracking base branch and brings in commits not
    # yet on the blocked head. Returns that second parent, or nil for any
    # other shape.
    def verified_base_parent(path, base_branch, blocked, head)
      parents = commit_parents(path, head)
      return nil unless parents && parents.length == 2 && parents.first == blocked

      base_tip = @gate.read(path, :branch_oid, branch: base_branch, remote: true)
      return nil unless base_tip.success?

      ancestor = @gate.read(path, :ancestor, base_oid: parents.last, head_oid: base_tip.stdout.strip.downcase)
      return nil unless ancestor.success?

      not_already_merged = @gate.read(path, :ancestor, base_oid: parents.last, head_oid: blocked)
      not_already_merged.exitstatus == 1 && !not_already_merged.overflow ? parents.last : nil
    end

    def commit_parents(path, oid)
      result = @gate.read(path, :object_content, oid: oid, max_stdout_bytes: MAX_COMMIT_BYTES)
      return nil unless result.success?

      header = result.stdout.split("\n\n", 2).first.to_s
      header.lines.filter_map { |line| line[/\Aparent ([0-9a-f]{40}(?:[0-9a-f]{24})?)$/, 1] }
    end

    def require_clean!(path)
      status = @gate.read(path, :status)
      return if status.success? && status.stdout.empty?

      raise Refused.new("dirty_worktree",
        "the owned review worktree #{path} has staged, unstaged or untracked changes; commit, stash or remove them " \
        "(`git -C #{Shellwords.escape(path)} status`), then retry. Hive never resets or overwrites them")
    end

    def retirement_document(receipt)
      Hive::Stages::Review::PassArchive.retirement_document(receipt, EXPIRY_REASON)
    end

    def retire!(receipt)
      archive = Hive::Stages::Review::PassArchive.retire!(
        @task, label: "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-base-merge-#{receipt.fetch('after_oid')[0, 12]}",
        expiry_reason: EXPIRY_REASON, receipt: receipt
      )
      receipt.merge("archive" => archive)
    end

    def record!(receipt)
      @activity.call&.record(
        kind: "recovery_recorded",
        operation_id: "review-base-merge:#{receipt.fetch('before_oid')}:#{receipt.fetch('after_oid')}",
        reason: "adopted the operator's base merge after a base conflict", source: "recovery_service",
        payload: { ACTIVITY_KEY => receipt }
      )
    rescue Hive::TaskActivity::Conflict
      # A retry after the activity was journaled: the deterministic operation
      # is already recorded with an earlier timestamp.
      nil
    end
  end
end
