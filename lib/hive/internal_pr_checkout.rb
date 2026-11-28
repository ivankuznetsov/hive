require "digest"
require "hive/lock"
require "hive/stages/review/pass_archive"
require "hive/internal_pr_checkout/git_transition"
require "hive/internal_pr_checkout/identity"
require "hive/internal_pr_checkout/reconciler"
require "hive/internal_pr_checkout/result"
require "hive/internal_pr_checkout/store"

module Hive
  # Authoritative domain facade for Hive-owned internal PR review checkouts
  # (`source: ad-hoc`).
  module InternalPrCheckout
    SNAPSHOT_RETRY_LIMIT = 4

    Snapshot = Data.define(
      :applicable,
      :status,
      :reason,
      :retryable,
      :guidance,
      :identity,
      :current,
      :generation,
      :reviewed_oid,
      :candidate_oid,
      :head_transition_digest,
      :pr_observation,
      :lease_version,
      :sampled_value
    ) do
      def applicable? = applicable == true
      def coherent? = status == "current"
      def busy? = status == "busy"
      def blocked? = status == "blocked"
    end

    module_function

    def applicable?(task, allow_any_stage: false)
      Identity.applicable?(task, allow_any_stage: allow_any_stage)
    end

    def reconcile(task:, mode: :explicit_reopen, deadline: nil, timeout_sec: nil, lock_held: false, **deps)
      Reconciler.new(**deps).reconcile(
        task: task,
        mode: mode,
        deadline: deadline,
        timeout_sec: timeout_sec,
        lock_held: lock_held
      )
    end

    def initialize_new_task!(task_folder:, task_id:, task_slug:, project:, pr_host:, pr_repository:,
                             pr_number:, pr_url:, base_ref_name:, head_ref_name:, head_repository:,
                             is_cross_repository:, pr_state:, branch:, head_oid:,
                             clock: -> { Time.now.utc })
      Store.new(task_folder).initialize_generation_one!(
        task_id: task_id,
        task_slug: task_slug,
        project: project,
        pr_host: pr_host,
        pr_repository: pr_repository,
        pr_number: pr_number,
        pr_url: pr_url,
        base_ref_name: base_ref_name,
        head_ref_name: head_ref_name,
        head_repository: head_repository,
        is_cross_repository: is_cross_repository,
        pr_state: pr_state,
        branch: branch,
        head_oid: head_oid,
        committed_at: clock.call
      )
    end

    def record_candidate!(task:, head_oid:, pass:, kind:, worktree_path: nil, **deps)
      Reconciler.new(**deps).record_candidate!(
        task: task,
        head_oid: head_oid,
        pass: pass,
        kind: kind,
        worktree_path: worktree_path
      )
    end

    # Keep the constant-anchor history root synchronized whenever an applicable
    # task retires or restores a PassArchive generation outside head change
    # (e.g. `hive approve` rewind/restore, `hive evidence rework`). Never
    # modifies `head_transition_digest`.
    def sync_history_after_pass_archive!(task:, label: nil, restored: false)
      return nil unless Identity.applicable?(task, allow_any_stage: true)

      store = Store.new(task.folder)
      return nil unless store.history_root_present? || store.current_present?

      if restored
        store.rebuild_history_after_restore!
      elsif label
        store.seal_retirement!(label: label)
        store.sync_current_history_root_digest!
      end
    end

    # Stable committed head-transition digest for `Attempts::Generation.artifact_token`.
    # Returns nil for non-applicable tasks, legacy implicit gen-1 tasks, and
    # newly created gen-1 tasks before any head transition (preserving pre-deploy
    # attempt identity per R12). Propagates pending/corrupt errors so callers
    # never hash an unreadable fallback.
    def attempt_generation_digest(task)
      return nil unless Identity.applicable?(task)

      store = Store.new(task.folder)
      if store.pending_present?
        # Validate pending so callers get pending_invalid vs transition_interrupted.
        store.read_pending
        raise Error.new(
          "transition_interrupted",
          "internal PR checkout transition is pending; cannot derive stable attempt generation",
          retryable: true
        )
      end

      return nil unless store.current_present?

      current = store.read_current
      store.verify_history_integrity! if store.history_root_present?
      current["head_transition_digest"]
    end

    # Consistent read-only snapshot API (U6.1).
    #
    # Under an already-held task lease, validates and samples once.
    # For read-only consumers without the lease, brackets the full projection
    # read with the same committed identity, absence of pending intent, and
    # identical idle SQLite lease version. Retries up to `max_retries` or
    # reports `busy`/`blocked` without returning torn values.
    def read_only_snapshot(task, lease_repository: nil, max_retries: SNAPSHOT_RETRY_LIMIT,
                           allow_any_stage: false, config: nil, &block)
      unless Identity.applicable?(task, allow_any_stage: allow_any_stage)
        snap = Snapshot.new(
          applicable: false, status: "not_applicable", reason: "not_internal_pr_review",
          retryable: false, guidance: "", identity: nil, current: nil, generation: nil,
          reviewed_oid: nil, candidate_oid: nil, head_transition_digest: nil,
          pr_observation: nil, lease_version: nil, sampled_value: nil
        )
        return block ? snap.with(sampled_value: block.call(snap)) : snap
      end

      store = Store.new(task.folder)
      held = Hive::Lock.task_lock_held?(task.folder)
      if held
        return sample_snapshot_once(task, store: store, config: config, lease_version: nil, &block)
      end

      repo = lease_repository || Hive::Lock.task_lease_repository
      max_retries.times do
        before = read_committed_boundary(task, store: store, lease_repository: repo)
        return before[:snapshot] if before[:snapshot]

        snap = sample_snapshot_once(
          task, store: store, config: config, lease_version: before[:lease_version], &block
        )
        return snap unless snap.coherent?

        after = read_committed_boundary(task, store: store, lease_repository: repo)
        return after[:snapshot] if after[:snapshot]

        if before[:token] == after[:token] && before[:lease_idle] && after[:lease_idle] &&
           before[:lease_version] == after[:lease_version]
          return snap
        end
      end

      Snapshot.new(
        applicable: true,
        status: "busy",
        reason: "task_locked",
        retryable: true,
        guidance: "internal PR checkout changed concurrently while sampling; retry",
        identity: nil,
        current: nil,
        generation: nil,
        reviewed_oid: nil,
        candidate_oid: nil,
        head_transition_digest: nil,
        pr_observation: nil,
        lease_version: nil,
        sampled_value: nil
      )
    end

    def sample_snapshot_once(task, store:, config:, lease_version:)
      if store.pending_present?
        return blocked_pending_snapshot(task, store: store)
      end

      identity = Identity.resolve!(task, config: config, allow_legacy_head_ref_oid: !store.current_present?)
      current = store.read_current
      store.verify_history_integrity! if store.history_root_present?
      generation = Hive::Stages::Review::PassArchive.generation(task.folder)
      reviewed_oid = current ? current.fetch("reviewed_oid") : identity.pr_head_oid
      candidate = store.read_candidate
      candidate_oid = candidate ? candidate.fetch("candidate_oid") : (current ? current.fetch("candidate_oid") : reviewed_oid)
      obs = build_snapshot_observation(current, identity, generation: generation)

      snap = Snapshot.new(
        applicable: true,
        status: "current",
        reason: "head_unchanged",
        retryable: false,
        guidance: "",
        identity: identity,
        current: current,
        generation: generation,
        reviewed_oid: reviewed_oid,
        candidate_oid: candidate_oid,
        head_transition_digest: current&.fetch("head_transition_digest", nil),
        pr_observation: obs,
        lease_version: lease_version,
        sampled_value: nil
      )
      block_given? ? snap.with(sampled_value: yield(snap)) : snap
    rescue Error => e
      Snapshot.new(
        applicable: true,
        status: "blocked",
        reason: e.reason,
        retryable: e.retryable,
        guidance: e.guidance,
        identity: nil,
        current: nil,
        generation: nil,
        reviewed_oid: nil,
        candidate_oid: nil,
        head_transition_digest: nil,
        pr_observation: nil,
        lease_version: lease_version,
        sampled_value: nil
      )
    end
    private_class_method :sample_snapshot_once

    def blocked_pending_snapshot(task, store:)
      pending = store.read_pending
      Snapshot.new(
        applicable: true,
        status: "blocked",
        reason: "transition_interrupted",
        retryable: true,
        guidance: "internal PR checkout transition #{pending['transaction_id']} was interrupted; reopen PR ##{pending['pr_number']} to recover",
        identity: nil,
        current: nil,
        generation: pending["old_generation"],
        reviewed_oid: pending["old_reviewed_oid"],
        candidate_oid: pending["old_candidate_oid"],
        head_transition_digest: nil,
        pr_observation: nil,
        lease_version: nil,
        sampled_value: nil
      )
    rescue Error => e
      Snapshot.new(
        applicable: true,
        status: "blocked",
        reason: e.reason,
        retryable: false,
        guidance: e.guidance,
        identity: nil,
        current: nil,
        generation: nil,
        reviewed_oid: nil,
        candidate_oid: nil,
        head_transition_digest: nil,
        pr_observation: nil,
        lease_version: nil,
        sampled_value: nil
      )
    end
    private_class_method :blocked_pending_snapshot

    def read_committed_boundary(task, store:, lease_repository:)
      lease = if lease_repository.respond_to?(:lease_snapshot)
        lease_repository.lease_snapshot(task.folder)
      else
        { idle: true, lease_version: 0 }
      end

      unless lease.fetch(:idle)
        return {
          snapshot: Snapshot.new(
            applicable: true,
            status: "busy",
            reason: "task_locked",
            retryable: true,
            guidance: "another Hive operation holds the task lease",
            identity: nil,
            current: nil,
            generation: nil,
            reviewed_oid: nil,
            candidate_oid: nil,
            head_transition_digest: nil,
            pr_observation: nil,
            lease_version: lease[:lease_version],
            sampled_value: nil
          )
        }
      end

      if store.pending_present?
        return { snapshot: blocked_pending_snapshot(task, store: store) }
      end

      token = [
        file_fingerprint(store.current_path),
        file_fingerprint(store.history_root_path),
        file_fingerprint(store.candidate_path),
        file_fingerprint(File.join(task.folder, "pr.md")),
        file_fingerprint(File.join(task.folder, "worktree.yml")),
        Hive::Stages::Review::PassArchive.generation(task.folder)
      ]
      { lease_idle: true, lease_version: lease[:lease_version], token: token }
    end
    private_class_method :read_committed_boundary

    def file_fingerprint(path)
      stat = File.lstat(path)
      return :symlink if stat.symlink?
      return :non_file unless stat.file?

      [ stat.dev, stat.ino, stat.size, stat.mtime.tv_sec, stat.mtime.tv_nsec,
        Digest::SHA256.hexdigest(File.open(path, File::RDONLY | File::NOFOLLOW, &:read)) ]
    rescue Errno::ENOENT
      :absent
    rescue SystemCallError
      :unreadable
    end
    private_class_method :file_fingerprint

    def build_snapshot_observation(current, identity, generation:)
      state = current&.dig("pr_state") || identity.pr_state
      return nil unless state

      {
        "number" => identity.pr_number,
        "url" => identity.pr_url,
        "pr_number" => identity.pr_number,
        "pr_url" => identity.pr_url,
        "pr_host" => identity.pr_host,
        "pr_repository" => identity.pr_repository,
        "state" => state,
        "head_oid" => current ? current.fetch("reviewed_oid") : identity.pr_head_oid,
        "base_ref_name" => current&.dig("base_ref_name") || identity.base_ref_name,
        "head_ref_name" => current&.dig("head_ref_name") || identity.head_ref_name,
        "head_repository" => current&.dig("head_repository") || identity.head_repository,
        "is_cross_repository" => current ? current["is_cross_repository"] == true : identity.is_cross_repository,
        "generation" => generation,
        "observed_at" => current&.dig("committed_at")
      }
    end
    private_class_method :build_snapshot_observation
  end
end
