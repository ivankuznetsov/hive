require "shellwords"
require "time"
require "hive/agent_git_gate"
require "hive/errors"
require "hive/gh"
require "hive/review_budget"
require "hive/review_publication_recovery"
require "hive/stages/review/pass_archive"
require "hive/task_activity"
require "hive/worktree"

module Hive
  # Adopts a review branch that was fast-forwarded outside Hive: an operator
  # or a delegated agent pushed commits onto the published PR branch, so the
  # PR head descends from the head Hive reviewed and nothing local is missing
  # from it. Review publication stops with `remote_fast_forward_adoptable`
  # (older runs recorded the same shape as `remote_conflict`); the recovery
  # coordinator calls #adopt! under the task lock before it clears that
  # REVIEW_ERROR marker, so a routine `workflow.retry` (or the daemon's own
  # retry) performs the adoption.
  #
  # Adoption fast-forwards the clean owned worktree to the exact re-observed PR
  # head through `Hive::AgentGitGate.fast_forward` (`merge --ff-only`, never a
  # reset, force or rebase), then retires the review generation the same way a
  # rewind or outcome-evidence rework does: review grants expire in the budget
  # audit and numbered passes move to `reviews/archive/`. The next review run
  # therefore starts at pass 1 on the adopted head and cannot reuse findings or
  # grant evidence bound to the old one.
  #
  # Only a provable fast-forward of a clean worktree is adopted. Anything that
  # is not one (true divergence, local-only commits, a deleted PR branch, a
  # worktree that moved elsewhere) returns nil so the caller keeps its ordinary
  # behavior; a fast-forward that cannot be applied safely raises Refused with
  # the exact operator action.
  class ReviewFastForwardAdoption
    MARKER_REASON = "review_publication_failed".freeze
    ADOPTABLE_FAILURES = %w[remote_conflict remote_fast_forward_adoptable].freeze
    EXPIRY_REASON = "remote_fast_forward_adopted".freeze
    ACTIVITY_KEY = "adopted_remote_fast_forward".freeze
    OID = Hive::ReviewPublicationRecovery::OID

    class Refused < Hive::Error
      attr_reader :reason, :owner

      def initialize(reason, message, owner: "operator")
        @reason = reason.to_s
        @owner = owner
        super(message)
      end
    end

    def self.candidate?(marker)
      marker.name.to_s == "review_error" && marker.attrs["reason"].to_s == MARKER_REASON &&
        ADOPTABLE_FAILURES.include?(marker.attrs["publication_reason"].to_s)
    end

    def initialize(task:, gate: Hive::AgentGitGate, remote_target: nil, allow_local_transport: false,
                   activity: -> { Hive::TaskActivity.for_task(task) })
      @task = task
      @gate = gate
      @remote_target = remote_target || method(:origin_push_target)
      @allow_local_transport = allow_local_transport
      @activity = activity
    end

    # Call only while holding the task lock. Returns nil when the marker does
    # not describe a provable fast-forward, otherwise the durable adoption
    # receipt (also when it completes an adoption interrupted after the merge).
    def adopt!(marker:)
      return nil unless self.class.candidate?(marker)

      evidence = Hive::ReviewPublicationRecovery.decode(marker.attrs) || {}
      reviewed = evidence["local_head"].to_s.downcase
      return nil unless reviewed.match?(OID) && Hive::Gh.parse_pull_request_url(evidence["pr_url"])

      path, branch = owned_worktree(evidence)
      head = head_oid(path)
      return nil unless head == reviewed || ancestor?(path, reviewed, head)

      target = @remote_target.call(path, evidence)
      observation = observe(path, branch, target)
      return nil unless observation.present?

      adopted = observation.oid
      if adopted == head
        # The PR names the reviewed head again (nothing to adopt), or an earlier
        # adoption merged before it was interrupted and only retirement remains.
        return nil if head == reviewed

        require_clean!(path)
      else
        require_present!(path, branch, adopted)
        classification = Hive::ReviewPublicationRecovery.classify(worktree: path, reference_oid: adopted, head: head)
        return nil unless classification.fetch("classification") == "behind"

        fast_forward!(path, branch, head, observation, target)
      end
      retire!(reviewed, adopted, branch, evidence["pr_url"])
    rescue Hive::AgentGitGate::Error => e
      # Unsafe repository-local Git config, or a merge that failed or could
      # not be verified: the worktree needs inspection before another try.
      raise Refused.new("git_unavailable", "the owned review worktree could not be read or fast-forwarded safely (#{e.message}); " \
        "inspect it with `git status` before retrying")
    end

    private

    def owned_worktree(evidence)
      pointer = Hive::Worktree.read_owned_pointer(
        @task.folder, project_root: @task.project_root, slug: @task.slug,
        expected_root: Hive::Worktree.canonical_root(@task.project_root)
      )
      path = pointer.fetch("path")
      recorded = evidence["worktree"].to_s
      unless evidence["branch"].to_s == pointer.fetch("branch") &&
             (recorded.empty? || File.realpath(recorded) == File.realpath(path))
        raise Refused.new("publication_identity_changed",
          "the recorded publication evidence names a different worktree or branch than the owned worktree; " \
          "run `hive status --operational --json` and inspect the task before retrying")
      end
      [ path, pointer.fetch("branch") ]
    rescue Hive::WorktreeError, KeyError, SystemCallError => e
      raise Refused.new("worktree_unavailable", "owned review worktree is unavailable (#{e.message}); repair worktree.yml before retrying")
    end

    def head_oid(path)
      result = @gate.read(path, :head_oid)
      raise Refused.new("worktree_unavailable", "owned review worktree HEAD cannot be read") unless result.success?

      result.stdout.strip.downcase
    end

    def ancestor?(path, base, head)
      @gate.read(path, :ancestor, base_oid: base, head_oid: head).success?
    end

    def origin_push_target(path, evidence)
      target = Hive::Gh.origin_push_url(path, managed: true)
      remote = Hive::Gh.repository_identity_from_remote(target)
      pr = Hive::Gh.parse_pull_request_url(evidence["pr_url"])
      unless remote.fetch("host").downcase == pr.fetch("host") &&
             remote.fetch("repository").downcase == pr.fetch("repository")
        raise Refused.new("publication_identity_changed",
          "origin no longer pushes to the pull request repository; repair the worktree remote before retrying")
      end
      target
    rescue Hive::GhError, Hive::AgentGitGate::Error => e
      raise Refused.new("remote_unavailable", "the pull-request remote cannot be resolved (#{e.message})", owner: "hive")
    end

    def observe(path, branch, target)
      @gate.observe_remote_branch(repository_path: path, branch: branch, remote: target,
                                  allow_local_transport: @allow_local_transport)
    rescue Hive::AgentGitGate::Error => e
      raise Refused.new("remote_observation_unavailable",
        "the pull-request branch could not be observed (#{e.message}); Hive re-observes it on the next retry", owner: "hive")
    end

    def require_clean!(path)
      status = @gate.read(path, :status)
      return if status.success? && status.stdout.empty?

      raise Refused.new("dirty_worktree", dirty_message(path))
    end

    def require_present!(path, branch, oid)
      return if @gate.read(path, :commit_oid, oid: oid).success?

      raise Refused.new("remote_object_unavailable",
        "the PR head #{oid} is not in the local object store; run " \
        "`git -C #{Shellwords.escape(path)} fetch origin #{Shellwords.escape(branch)}`, then retry")
    end

    def fast_forward!(path, branch, head, observation, target)
      require_clean!(path)
      budget = Hive::ReviewBudget.new(task: @task, project: @task.project_name)
      budget.store.records if budget.present?
      @gate.fast_forward(repository_path: path, branch: branch, expected_oid: head, observation: observation,
                         remote: target, allow_local_transport: @allow_local_transport)
    rescue Hive::AgentGitGate::FastForwardRefused => e
      raise Refused.new(e.reason, e.reason == :dirty_worktree ? dirty_message(path) : "fast-forward refused: #{e.message}")
    rescue Hive::AgentGitGate::RemoteConflict => e
      raise Refused.new("remote_moved", "#{e.message}; Hive re-observes the PR head on the next retry", owner: "hive")
    end

    def dirty_message(path)
      "the owned review worktree #{path} has staged, unstaged or untracked changes; commit, stash or remove them " \
        "(`git -C #{Shellwords.escape(path)} status`), then retry. Hive never resets or overwrites them"
    end

    def retire!(reviewed, adopted, branch, pr_url)
      receipt = { "before_oid" => reviewed, "after_oid" => adopted, "branch" => branch, "pr_url" => pr_url }
      archive = Hive::Stages::Review::PassArchive.retire!(
        @task, label: "#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-remote-fast-forward-#{adopted[0, 12]}",
        expiry_reason: EXPIRY_REASON, receipt: receipt
      )
      receipt = receipt.merge("archive" => archive)
      @activity.call&.record(
        kind: "recovery_recorded", operation_id: "review-remote-fast-forward:#{reviewed}:#{adopted}",
        reason: "adopted an external fast-forward of the review branch", source: "recovery_service",
        payload: { ACTIVITY_KEY => receipt }
      )
      receipt
    end
  end
end
