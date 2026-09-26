require "test_helper"
require "hive/attempts/reconciler"
require "hive/runtime_control_plane/lifecycle_repository"

class AttemptsReconcilerTest < Minitest::Test
  include HiveTestHelper

  NOW = Time.utc(2026, 7, 16, 12, 0, 0)
  CLAIM_CAPABILITY = "c" * 64
  OWNER = {
    "pid" => 123,
    "start_fingerprint" => "start-1",
    "session_id" => 123,
    "process_group_id" => 123
  }.freeze

  FakeIdentity = Struct.new(:owner_status) do
    def status(_owner) = owner_status
  end

  InterruptionIdentity = Struct.new(:wrapper_status, :worker_status) do
    def status(_owner) = wrapper_status
    def orphan_group_status(wrapper:, worker:) = worker_status
  end

  class FakeLogger
    attr_reader :events

    def initialize = @events = []
    def event(name, **fields) = @events << [ name, fields ]
  end

  def test_unclaimed_and_claimed_launch_deadlines_transition_once_to_lost
    with_store do |store|
      unclaimed = create(store, attempt_id: "unclaimed", timeout: 1)
      claimed_base = create(store, attempt_id: "claimed", timeout: 30)
      claimed = store.claim(
        claimed_base, owner: OWNER, claim_capability: CLAIM_CAPABILITY,
        first_heartbeat_timeout_sec: 1, now: NOW
      )
      reconciler = reconciler(store, :missing)

      first = reconciler.reconcile(now: NOW + 2)
      second = reconciler.reconcile(now: NOW + 3)

      assert_equal %w[claimed unclaimed], first.lost_attempts.map(&:attempt_id).sort
      assert_equal %w[claimed unclaimed], second.lost_attempts.map(&:attempt_id).sort
      assert_empty second.newly_lost_attempts
      assert_equal "launch_timeout", store.fetch(unclaimed.attempt_id)["loss"]["reason"]
      assert_equal "first_heartbeat_timeout", store.fetch(claimed.attempt_id)["loss"]["reason"]
    end
  end

  def test_fresh_matching_owner_is_adopted_without_waiting_on_child_status
    with_store do |store|
      running = running_attempt(store, stale_sec: 30)
      snapshot = reconciler(store, :matching).reconcile(now: NOW + 2)

      status = snapshot.attempts.find { |candidate| candidate.attempt.attempt_id == running.attempt_id }
      assert_equal :adopted, status.classification
      assert_equal "running", store.fetch(running.attempt_id).state
      assert_equal 1, snapshot.capacity.global_count
    end
  end

  def test_stale_matching_owner_is_suspect_and_still_reserves_capacity
    with_store do |store|
      running = running_attempt(store, stale_sec: 1)
      snapshot = reconciler(store, :matching).reconcile(now: NOW + 5)

      status = snapshot.attempts.first
      assert_equal :suspect, status.classification
      assert_equal "running", store.fetch(running.attempt_id).state
      assert_equal [ running.attempt_id ], snapshot.capacity.reserved_attempt_ids
    end
  end

  def test_fresh_heartbeat_with_reused_or_missing_pid_is_lost_not_adopted
    %i[mismatched missing].each do |owner_status|
      with_store do |store|
        running = running_attempt(store, stale_sec: 30)
        snapshot = reconciler(store, owner_status).reconcile(now: NOW + 2)

        assert_equal [ running.attempt_id ], snapshot.newly_lost_attempts.map(&:attempt_id)
        lost = store.fetch(running.attempt_id)
        assert_equal "lost", lost.state
        expected = owner_status == :mismatched ? "owner_identity_mismatch" : "owner_gone"
        assert_equal expected, lost["loss"]["reason"]
      end
    end
  end

  def test_loss_reconciliation_uses_the_admitted_workers_cleanup_window
    with_store do |store|
      running = running_attempt(store, stale_sec: 30)
      Hive::RuntimeControlPlane::LifecycleRepository.new(
        database: store.database
      ).begin_quiesce!(
        deadline_monotonic: 700, boot_id: "boot", shutdown_grace_sec: 120
      )

      snapshot = reconciler(store, :missing).reconcile(now: NOW + 2)

      assert_equal [ running.attempt_id ], snapshot.newly_lost_attempts.map(&:attempt_id)
      assert_equal "lost", store.fetch(running.attempt_id).state
      assert_equal 1, store.database.read { |db| db[:quiescence_cleanup_writes].count }
    end
  end

  def test_unverifiable_owner_fails_closed_as_suspect
    with_store do |store|
      running = running_attempt(store, stale_sec: 30)
      snapshot = reconciler(store, :unverifiable).reconcile(now: NOW + 2)

      assert_empty snapshot.lost_attempts
      assert_equal :suspect, snapshot.attempts.first.classification
      assert_equal "running", store.fetch(running.attempt_id).state
      assert_equal 1, snapshot.capacity.global_count
    end
  end

  def test_valid_terminal_receipt_has_highest_precedence
    with_store do |store|
      running = running_attempt(store, stale_sec: 30)
      terminal = store.terminalize(
        running, outcome: "succeeded", exit_status: 0,
        final_checkpoint: running.checkpoint,
        output_references: [],
        log_reference: { "path" => "logs/a.frames", "size" => 0, "sha256" => "0" * 64 },
        now: NOW + 2
      )

      snapshot = reconciler(store, :missing).reconcile(now: NOW + 3)

      assert_empty snapshot.lost_attempts
      assert_equal [ terminal.attempt_id ], snapshot.terminal_attempts.map(&:attempt_id)
      assert_equal :terminal, snapshot.attempts.first.classification
    end
  end

  def test_verified_stopped_attempt_becomes_interrupted_and_retains_checkpoint_and_outputs
    with_store do |store|
      running = running_attempt(store, stale_sec: 30)
      writer = store.log_archive.open_writer(running.attempt_id)
      writer.append(:stdout, "partial output\n")
      writer.close
      output_path = store.output_path(running.attempt_id, "checkpoint.txt", create_directory: true)
      File.write(output_path, "retained\n")
      reference = Hive::OutputReference.build(output_path, root: store.root)
      worker = OWNER.merge(
        "pid" => 456, "start_fingerprint" => "worker-start",
        "process_group_id" => 456
      )
      running = store.checkpoint(
        running, checkpoint: { "revision" => "rev-2", "progress_token" => "progress" },
        worker: worker, output_references: [ reference ], now: NOW + 2
      )
      service = Hive::Attempts::Reconciler.new(
        store: store,
        process_identity: InterruptionIdentity.new(:missing, :absent)
      )

      result = service.finalize_interruption(
        running, pause_generation: 4, now: NOW + 3
      )

      assert_equal :interrupted, result.classification
      assert_equal "interrupted", result.attempt.outcome
      assert_equal 4, result.attempt.receipt.fetch("pause_generation")
      assert_equal running.checkpoint, result.attempt.receipt.fetch("final_checkpoint")
      assert_equal [ reference ], result.attempt.receipt.fetch("output_references")
      assert_equal "partial output\n",
                   store.read_log(running.attempt_id).frames.map(&:bytes).join
    end
  end

  def test_interruption_remains_unverified_while_any_owned_identity_may_be_live
    [
      InterruptionIdentity.new(:matching, :absent),
      InterruptionIdentity.new(:unverifiable, :absent),
      InterruptionIdentity.new(:missing, :matching),
      InterruptionIdentity.new(:missing, :unverifiable)
    ].each do |identity|
      with_store do |store|
        running = running_attempt(store, stale_sec: 30)
        running = store.checkpoint(
          running, checkpoint: running.checkpoint,
          worker: OWNER.merge("pid" => 456, "process_group_id" => 456), now: NOW + 2
        )
        result = Hive::Attempts::Reconciler.new(
          store: store, process_identity: identity
        ).finalize_interruption(running, pause_generation: 2, now: NOW + 3)

        assert_includes %i[still_running unverifiable], result.classification
        assert_equal "running", store.fetch(running.attempt_id).state
      end
    end
  end

  def test_interruption_remains_unverified_without_a_durable_log_reference
    with_store do |store|
      running = running_attempt(store, stale_sec: 30)
      running = store.checkpoint(
        running, checkpoint: running.checkpoint,
        worker: OWNER.merge("pid" => 456, "process_group_id" => 456), now: NOW + 2
      )

      result = Hive::Attempts::Reconciler.new(
        store: store,
        process_identity: InterruptionIdentity.new(:missing, :absent)
      ).finalize_interruption(running, pause_generation: 2, now: NOW + 3)

      assert_equal :unverifiable, result.classification
      assert_equal "unavailable", result.evidence.fetch(:log)
      assert_equal "running", store.fetch(running.attempt_id).state
    end
  end

  def test_genuine_terminal_receipt_wins_interruption_compare_and_swap_race
    with_store do |store|
      running = running_attempt(store, stale_sec: 30)
      running = store.checkpoint(
        running, checkpoint: running.checkpoint,
        worker: OWNER.merge("pid" => 456, "process_group_id" => 456), now: NOW + 2
      )
      writer = store.log_archive.open_writer(running.attempt_id)
      writer.close
      interrupt = store.method(:interrupt)
      store.define_singleton_method(:interrupt) do |observed, **kwargs|
        terminalize(
          observed, outcome: "succeeded", exit_status: 0,
          final_checkpoint: observed.checkpoint,
          output_references: observed["current_outputs"],
          log_reference: Hive::OutputReference.build(
            log_archive.hot_path(observed.attempt_id), root: root
          ), now: kwargs.fetch(:now)
        )
        interrupt.call(observed, **kwargs)
      end
      service = Hive::Attempts::Reconciler.new(
        store: store,
        process_identity: InterruptionIdentity.new(:missing, :absent)
      )

      result = service.finalize_interruption(
        running, pause_generation: 3, now: NOW + 3
      )

      assert_equal :terminal, result.classification
      assert_equal "succeeded", result.attempt.outcome
      assert_nil result.attempt.receipt.fetch("pause_generation")
    end
  end

  def test_nonterminal_compare_and_swap_winner_is_retried_by_the_caller
    with_store do |store|
      running = running_attempt(store, stale_sec: 30)
      writer = store.log_archive.open_writer(running.attempt_id)
      writer.close
      store.define_singleton_method(:interrupt) do |*|
        raise Hive::Attempts::CompareAndSwapFailed, "lost race"
      end

      assert_raises(Hive::Attempts::CompareAndSwapFailed) do
        Hive::Attempts::Reconciler.new(
          store: store,
          process_identity: InterruptionIdentity.new(:missing, :absent)
        ).finalize_interruption(running, pause_generation: 2, now: NOW + 3)
      end
    end
  end

  def test_interruption_log_resolution_errors_remain_unverifiable
    with_store do |store|
      running = running_attempt(store, stale_sec: 30)
      store.log_archive.define_singleton_method(:resolve) { |_| raise IOError, "offline" }
      reconciler = Hive::Attempts::Reconciler.new(store: store)

      assert_nil reconciler.send(:interruption_log_reference, running)
    end
  end

  def test_commits_alone_never_infer_success_and_matching_marker_only_records_evidence
    with_tmp_git_repo do |project_root|
      task_folder = File.join(project_root, ".hive-state", "stages", "4-execute", "durable-task")
      FileUtils.mkdir_p(task_folder)
      File.write(File.join(task_folder, "meta.yml"), { "id" => "42" }.to_yaml)
      File.write(File.join(task_folder, "worktree.yml"), { "path" => project_root }.to_yaml)
      state_file = File.join(task_folder, "task.md")
      File.write(state_file, "# task\n")
      3.times do |index|
        File.write(File.join(project_root, "commit-#{index}.txt"), "#{index}\n")
        run!("git", "-C", project_root, "add", "commit-#{index}.txt")
        run!("git", "-C", project_root, "commit", "-m", "commit #{index}", "--quiet")
      end
      project = {
        "name" => "demo", "path" => project_root,
        "hive_state_path" => File.join(project_root, ".hive-state")
      }
      original = Hive::Config.method(:find_project)
      Hive::Config.define_singleton_method(:find_project) { |_name| project }

      with_store do |store|
        running = running_attempt(store, stale_sec: 30)
        first = reconciler(store, :missing).reconcile(now: NOW + 2)
        lost = first.lost_attempts.first
        assert_equal "git_inventory", lost["diagnostics"]["evidence_precedence"]
        assert_equal false, lost["diagnostics"].dig("git_inventory", "success_inferred")
      end

      with_store do |store|
        running = running_attempt(store, stale_sec: 30)
        Hive::Markers.set(
          state_file, :complete,
          attempt_id: running.attempt_id,
          task_generation: running.task_generation
        )
        second = reconciler(store, :missing).reconcile(now: NOW + 2)
        lost = second.lost_attempts.first
        assert_equal "lost", lost.state
        assert_equal "current_generation_marker", lost["diagnostics"]["evidence_precedence"]
        assert_equal true, lost["diagnostics"].dig("marker_evidence", "terminal")
      end
    ensure
      Hive::Config.define_singleton_method(:find_project, original) if original
    end
  end

  def test_unexpired_launches_are_reserved_or_adopted_without_spawning
    with_store do |store|
      unclaimed = create(store, attempt_id: "unclaimed", timeout: 30)
      claimed = create(store, attempt_id: "claimed", timeout: 30)
      store.claim(
        claimed, owner: OWNER, claim_capability: CLAIM_CAPABILITY,
        first_heartbeat_timeout_sec: 30, now: NOW
      )

      matching = reconciler(store, :matching)
      snapshot = matching.reconcile(now: NOW + 1)
      classes = snapshot.attempts.to_h { |status| [ status.attempt.attempt_id, status.classification ] }
      assert_equal :reserved, classes.fetch(unclaimed.attempt_id)
      assert_equal :adopted, classes.fetch(claimed.attempt_id)
      assert_equal store.fetch(claimed.attempt_id).attempt_id, matching.fetch(claimed.attempt_id).attempt_id
    end

    with_store do |store|
      claimed = create(store, attempt_id: "claimed", timeout: 30)
      store.claim(
        claimed, owner: OWNER, claim_capability: CLAIM_CAPABILITY,
        first_heartbeat_timeout_sec: 30, now: NOW
      )
      assert_equal :suspect, reconciler(store, :missing).reconcile(now: NOW + 1).attempts.first.classification
    end
  end

  def test_competing_reconciler_cas_loss_is_ignored_until_next_scan
    with_store do |store|
      running_attempt(store, stale_sec: 30)
      store.define_singleton_method(:mark_lost) do |*_args, **_kwargs|
        raise Hive::Attempts::CompareAndSwapFailed
      end
      snapshot = reconciler(store, :missing).reconcile(now: NOW + 2)
      assert_empty snapshot.attempts
      assert_empty snapshot.newly_lost_attempts
      assert_equal 1, snapshot.capacity.global_count
    end
  end

  def test_task_and_git_inventory_errors_remain_non_success_evidence
    with_tmp_dir do |root|
      task_folder = File.join(root, ".hive-state", "stages", "4-execute", "durable-task")
      FileUtils.mkdir_p(task_folder)
      File.write(File.join(task_folder, "task.md"), "# malformed task\n")
      project = { "name" => "demo", "hive_state_path" => File.join(root, ".hive-state") }
      with_replaced_singleton_method(Hive::Config, :find_project, ->(_name) { project }) do
        with_store do |store|
          record = create(store)
          with_replaced_singleton_method(Hive::Task, :new, ->(_folder) { raise Hive::InvalidTaskPath }) do
            assert_nil reconciler(store, :missing).send(:locate_task, record)
          end
        end
      end

      fake_task = Struct.new(:worktree_path).new(root)
      with_replaced_singleton_method(Open3, :capture2, ->(*_args) { raise Errno::EACCES }) do
        inventory = reconciler(Object.new, :missing).send(:git_inventory, fake_task)
        assert_equal true, inventory.fetch("unreadable")
        assert_equal false, inventory.fetch("success_inferred")
      end
    end
  end

  def test_lifecycle_and_invalid_record_logging_is_correlated_and_deduplicated
    with_store do |store|
      launching = create(store, attempt_id: "launching")
      claimed_base = create(store, attempt_id: "claimed")
      claimed = store.claim(
        claimed_base, owner: OWNER, claim_capability: CLAIM_CAPABILITY,
        first_heartbeat_timeout_sec: 30, now: NOW
      )
      running = running_attempt(store, stale_sec: 30)
      terminal = store.terminalize(
        running, outcome: "succeeded", exit_status: 0,
        final_checkpoint: running.checkpoint, output_references: [],
        log_reference: { "path" => "logs/a", "size" => 0, "sha256" => "0" * 64 },
        now: NOW + 2
      )
      lost_base = create(store, attempt_id: "lost")
      lost = store.mark_lost(lost_base, reason: "timeout", now: NOW + 31)
      logger = FakeLogger.new
      observer = Hive::Attempts::Reconciler.new(
        store: store, process_identity: FakeIdentity.new(:matching), logger: logger
      )
      statuses = [
        Hive::Attempts::ReconciledAttempt.new(
          attempt: launching, classification: :reserved, owner_status: :not_claimed, evidence: {}
        ),
        Hive::Attempts::ReconciledAttempt.new(
          attempt: claimed, classification: :adopted, owner_status: :matching, evidence: {}
        ),
        Hive::Attempts::ReconciledAttempt.new(
          attempt: running, classification: :adopted, owner_status: :matching, evidence: {}
        ),
        Hive::Attempts::ReconciledAttempt.new(
          attempt: running, classification: :suspect, owner_status: :unverifiable, evidence: {}
        ),
        Hive::Attempts::ReconciledAttempt.new(
          attempt: terminal, classification: :terminal, owner_status: :not_applicable, evidence: {}
        ),
        Hive::Attempts::ReconciledAttempt.new(
          attempt: lost, classification: :lost, owner_status: :missing, evidence: {}
        )
      ]
      statuses.each { |status| observer.send(:log_reconciliation, status) }
      statuses.each { |status| observer.send(:log_reconciliation, status) }
      assert_equal %i[
        attempt_accepted attempt_claimed attempt_running attempt_adopted
        attempt_suspect attempt_terminal attempt_lost
      ], logger.events.map(&:first)

      unknown = Hive::Attempts::ReconciledAttempt.new(
        attempt: running, classification: :unchanged, owner_status: :matching, evidence: {}
      )
      assert_equal [], observer.send(:log_reconciliation, unknown)
    end
  end

  def test_condition_observer_receives_each_reconciled_attempt_before_snapshot_return
    with_store do |store|
      create(store)
      observed = []
      observer = lambda { |status, now:| observed << [ status.classification, now ] }
      snapshot = Hive::Attempts::Reconciler.new(
        store: store, process_identity: FakeIdentity.new(:matching),
        condition_observer: observer
      ).reconcile(now: NOW + 1)

      assert_equal 1, snapshot.attempts.size
      assert_equal [ [ :reserved, NOW + 1 ] ], observed
    end
  end

  def test_finalization_prepares_before_observation_and_acks_only_durable_journal_result
    with_store do |store|
      running = running_attempt(store, stale_sec: 30)
      terminal = store.terminalize(
        running, outcome: "succeeded", exit_status: 0,
        final_checkpoint: running.checkpoint, output_references: [],
        log_reference: { "path" => "logs/a", "size" => 0, "sha256" => "0" * 64 },
        now: NOW + 2
      )
      events = []
      finalization = Object.new
      finalization.define_singleton_method(:prepare) do |record|
        events << [ :prepare, record.attempt_id ]
        true
      end
      finalization.define_singleton_method(:acknowledge) do |record, consumer|
        events << [ :acknowledge, record.attempt_id, consumer ]
      end
      finalization.define_singleton_method(:publish_after_journal) do |record|
        events << [ :publish_after_journal, record.attempt_id ]
      end
      observer = Object.new
      observer.define_singleton_method(:observe) do |status, now:|
        events << [ :observe, status.attempt.attempt_id, now ]
        :acknowledged
      end

      Hive::Attempts::Reconciler.new(
        store: store, process_identity: FakeIdentity.new(:missing),
        condition_observer: observer, finalization_maintenance: finalization
      ).reconcile(now: NOW + 3)

      assert_equal [
        [ :prepare, terminal.attempt_id ],
        [ :observe, terminal.attempt_id, NOW + 3 ],
        [ :acknowledge, terminal.attempt_id, :journal ],
        [ :publish_after_journal, terminal.attempt_id ]
      ], events

      events.clear
      observer.define_singleton_method(:observe) do |status, now:|
        events << [ :observe, status.attempt.attempt_id, now ]
        :pending
      end
      Hive::Attempts::Reconciler.new(
        store: store, process_identity: FakeIdentity.new(:missing),
        condition_observer: observer, finalization_maintenance: finalization
      ).reconcile(now: NOW + 4)
      refute events.any? { |event| event.first == :acknowledge }
    end
  end

  def test_reconciliation_builds_capacity_and_admission_view_from_one_hot_attempts
    with_store do |store|
      create(store)
      scans = 0
      original_active_attempts = store.method(:active_attempts)
      store.define_singleton_method(:active_attempts) do
        scans += 1
        original_active_attempts.call
      end
      snapshot = reconciler(store, :matching).reconcile(now: NOW + 1)

      assert_equal 1, scans
      assert_equal [ "attempt-1" ], snapshot.admission_view.records.map(&:attempt_id)
      assert_equal snapshot.capacity,
                   snapshot.admission_view.capacity(now: NOW + 1)
    end
  end

  def test_operational_storage_status_uses_the_current_hot_snapshot_counts
    with_store do |store|
      create(store)
      service = reconciler(store, :matching)
      snapshot = service.reconcile(now: NOW + 1)

      status = service.operational_storage_status(snapshot)

      assert_equal "unknown", status.fetch("status")
      assert_equal 1, status.dig("hot", "records")
      assert_equal 0, status.dig("hot", "invalid")

      unavailable = service.operational_storage_status(nil)
      assert_equal({ "records" => nil, "invalid" => nil }, unavailable.fetch("hot"))

      maintenance = Object.new
      call = nil
      maintenance.define_singleton_method(:storage_snapshot) do |**values|
        call = values
        { "status" => "healthy" }
      end
      maintained = Hive::Attempts::Reconciler.new(
        store: store, process_identity: FakeIdentity.new(:matching),
        finalization_maintenance: maintenance
      )
      assert_equal "healthy", maintained.operational_storage_status(snapshot).fetch("status")
      assert_equal({ hot_count: 1, invalid_hot_count: 0 }, call)
    end
  end

  private

  def with_store
    with_tmp_dir do |root|
      yield Hive::Attempts::Repository.new(root: root, migrate: true)
    end
  end

  def reconciler(store, owner_status)
    Hive::Attempts::Reconciler.new(
      store: store,
      process_identity: FakeIdentity.new(owner_status)
    )
  end

  def create(store, attempt_id: "attempt-1", timeout: 30)
    store.create_launching(
      attempt_id: attempt_id, request_id: "request-#{attempt_id}",
      task_id: "42", project: "demo", task_slug: "durable-task",
      intended_stage: "4-execute", task_generation: "generation-#{attempt_id}",
      progress_token: "progress", provider: "codex",
      worker_argv: [ "hive", "run", "durable-task" ],
      claim_capability_digest: Hive::Attempts::Capability.digest(CLAIM_CAPABILITY), starting_revision: nil,
      retry_charge: 0, inherited_outputs: [], launch_timeout_sec: timeout, now: NOW
    )
  end

  def running_attempt(store, stale_sec:)
    launching = create(store)
    claimed = store.claim(
      launching, owner: OWNER, claim_capability: CLAIM_CAPABILITY,
      first_heartbeat_timeout_sec: 30, now: NOW
    )
    store.first_heartbeat(claimed, stale_sec: stale_sec, now: NOW + 1)
  end
end
