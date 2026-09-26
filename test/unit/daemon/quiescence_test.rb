require "test_helper"
require "hive/daemon/quiescence"
require "hive/runtime_control_plane/database"
require "hive/runtime_control_plane/lifecycle_repository"
require "hive/runtime_control_plane/process_registry"

class HiveDaemonQuiescenceTest < Minitest::Test
  include HiveTestHelper

  class SequenceCapability
    def initialize(*verdicts)
      @verdicts = verdicts
    end

    def call
      @verdicts.length > 1 ? @verdicts.shift : @verdicts.fetch(0)
    end
  end

  class ManualClock
    attr_reader :now

    def initialize(now = 100.0)
      @now = now
    end

    def call = @now
    def sleep(seconds) = @now += [ Float(seconds), 0.001 ].max
  end

  class FixedIdentity
    attr_accessor :state

    def initialize(state = :matching)
      @state = state
    end

    def status(_identity) = state
    def capture(pid)
      Hive::Attempts::ProcessSnapshot.new(
        pid: Integer(pid), start_fingerprint: "start-#{pid}",
        session_id: Integer(pid), process_group_id: Integer(pid)
      )
    end

    def orphan_group_status(wrapper:, worker:) = :absent
  end

  class MappedIdentity < FixedIdentity
    def initialize(states)
      @states = states
      super(:unverifiable)
    end

    def status(identity) = @states.fetch(identity["pid"] || identity[:pid], state)
  end

  def test_open_admission_precheck_refusal_is_non_disruptive
    with_runtime do |root, database|
      signals = []
      result = coordinator(
        root, database,
        capability: SequenceCapability.new(refusal("agent_attempt_root")),
        signaler: ->(*args) { signals << args }
      ).call

      assert_equal false, result.paused
      assert_equal "ownership_unverifiable", result.reason
      assert result.admission_open
      assert_nil result.generation
      assert_equal "agent_attempt_root", result.capability.reason
      assert_empty signals
      assert_equal "running", lifecycle(database).phase
      refute File.exist?(Hive::Paths.runtime_quiescence_proof_path(root))
    end
  end

  def test_closed_generation_precheck_refusal_preserves_generation
    with_runtime do |root, database|
      closed = Hive::RuntimeControlPlane::LifecycleRepository.new(
        database: database
      ).begin_quiesce!(
        deadline_monotonic: 200, boot_id: "boot-test", shutdown_grace_sec: 25
      )

      result = coordinator(
        root, database,
        capability: SequenceCapability.new(refusal("agent_attempt_root"))
      ).call

      refute result.paused
      refute result.admission_open
      assert_equal closed.generation, result.generation
      assert_equal closed.generation, lifecycle(database).generation
      assert_equal "quiescing", lifecycle(database).phase
    end
  end

  def test_post_closure_recheck_refusal_keeps_admission_closed_without_signals
    with_runtime do |root, database|
      signals = []
      result = coordinator(
        root, database,
        capability: SequenceCapability.new(eligible, refusal("unproven_launch_surface")),
        signaler: ->(*args) { signals << args }
      ).call

      refute result.paused
      refute result.admission_open
      assert_equal "ownership_unverifiable", result.reason
      assert_equal "unproven_launch_surface", result.capability.reason
      assert_equal 1, result.generation
      assert_empty signals
      assert_equal "quiescing", lifecycle(database).phase
    end
  end

  def test_operation_lock_busy_leaves_open_admission_unchanged
    with_runtime do |root, database|
      lock = Object.new
      lock.define_singleton_method(:synchronize) do
        raise Hive::ConcurrentRunError.new("busy", lock_path: "/operation")
      end

      result = coordinator(
        root, database, capability: SequenceCapability.new(eligible),
        operation_lock_factory: ->(_timeout) { lock }
      ).call

      refute result.paused
      assert_equal "controller_busy", result.reason
      assert result.admission_open
      assert_nil result.generation
      assert_equal "running", lifecycle(database).phase
    end
  end

  def test_launch_fence_timeout_keeps_closed_generation_without_drain
    with_runtime do |root, database|
      fence = Object.new
      fence.define_singleton_method(:acquire_exclusive!) do
        raise Hive::ConcurrentRunError.new("busy", lock_path: "/launch")
      end
      signals = []

      result = coordinator(
        root, database, capability: SequenceCapability.new(eligible),
        launch_fence_factory: ->(_timeout) { fence },
        signaler: ->(*args) { signals << args }
      ).call

      refute result.paused
      assert_equal "launch_fence_busy", result.reason
      refute result.admission_open
      assert_equal 1, result.generation
      assert_empty signals
      assert_equal "quiescing", lifecycle(database).phase
    end
  end

  def test_deadline_exhaustion_before_closure_leaves_admission_open
    with_runtime do |root, database|
      clock = ManualClock.new
      advancing_capability = Object.new
      advancing_capability.define_singleton_method(:call) do
        clock.sleep(0.7)
        Hive::RuntimeControlPlane::CapabilityVerdict.new(
          eligible: true, reason: nil, ownership_mode: "registered_only",
          disqualifying_inventory: []
        )
      end

      result = coordinator(
        root, database, timeout_sec: 1, capability: advancing_capability,
        monotonic: clock.method(:call), sleeper: clock.method(:sleep)
      ).call

      assert_equal "deadline_exhausted", result.reason
      assert result.admission_open
      assert_nil result.generation
      assert_equal "running", lifecycle(database).phase
    end
  end

  def test_busy_sqlite_writer_is_bounded_before_closure_and_leaves_admission_open
    with_runtime do |root, database|
      blocker = SQLite3::Database.new(database.path)
      blocker.execute("BEGIN IMMEDIATE")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      result = coordinator(
        root, database, timeout_sec: 0.1,
        capability: SequenceCapability.new(eligible)
      ).call

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      refute result.paused
      assert_equal "deadline_exhausted", result.reason
      assert result.admission_open
      assert_nil result.generation
      assert_operator elapsed, :<, 0.5
      assert_equal "running", lifecycle(database).phase
    ensure
      blocker&.execute("ROLLBACK")
      blocker&.close
    end
  end

  def test_empty_eligible_installation_checkpoints_disconnects_and_publishes_bound_proof
    with_runtime do |root, database|
      result = coordinator(
        root, database,
        capability: SequenceCapability.new(eligible, eligible)
      ).call

      assert result.paused
      assert_equal "paused", result.status
      refute result.admission_open
      assert_equal 1, result.generation
      assert result.checkpoint.fetch(:complete)
      assert database.disconnected?

      database.open!
      state = lifecycle(database)
      identity = database.installation_identity.fetch(:installation_id)
      verdict = Hive::Daemon::FinalizationProof.new(state_home: root).verify(
        lifecycle: state, installation_id: identity
      )
      assert verdict.valid?, verdict.reason
      assert_equal state.revision, verdict.payload.fetch("lifecycle_revision")
      assert_equal state.mutation_sequence, verdict.payload.fetch("mutation_sequence")
    end
  end

  def test_remaining_worker_times_out_and_aggregates_identity_evidence
    with_runtime do |root, database|
      insert_owned_process(database, pid: 42_424)
      clock = ManualClock.new
      signals = []
      identity = FixedIdentity.new(:matching)

      result = coordinator(
        root, database, timeout_sec: 0.1,
        capability: SequenceCapability.new(eligible, eligible),
        process_identity: identity, monotonic: clock.method(:call),
        sleeper: clock.method(:sleep), signaler: ->(signal, pid) { signals << [ signal, pid ] }
      ).call

      refute result.paused
      assert_equal "timeout", result.reason
      refute result.admission_open
      assert_equal 1, result.generation
      assert_equal [ 42_424 ], result.remaining.map { |entry| entry.fetch("pid") }.uniq
      assert_includes signals, [ "TERM", 42_424 ]
      assert_includes signals, [ "KILL", 42_424 ]
      assert_equal "quiescing", lifecycle(database).phase
    end
  end

  def test_delegated_descendant_remains_visible_after_its_registered_root_exits
    with_runtime do |root, database|
      insert_owned_process(
        database, pid: 42_424, custody_mode: "delegated_cgroup_v2",
        custody_path: "/hive/installation"
      )
      clock = ManualClock.new
      identity = MappedIdentity.new(42_424 => :missing, 42_425 => :matching)
      custody = Object.new
      custody.define_singleton_method(:members) { |_path, timeout_sec:| [ 42_425 ] }
      signals = []

      result = coordinator(
        root, database, timeout_sec: 0.1,
        capability: SequenceCapability.new(eligible, eligible),
        process_identity: identity, custody: custody,
        monotonic: clock.method(:call), sleeper: clock.method(:sleep),
        signaler: ->(signal, pid) { signals << [ signal, pid ] }
      ).call

      refute result.paused
      assert_equal "timeout", result.reason
      assert_equal [ 42_425 ], result.remaining.first.fetch("descendants").map { |entry| entry.fetch("pid") }
      assert_includes signals, [ "TERM", 42_425 ]
      assert_includes signals, [ "KILL", 42_425 ]
      refute_includes signals, [ "TERM", 42_424 ]
      refute_includes signals, [ "KILL", 42_424 ]
    end
  end

  def test_signal_permission_failure_remains_explicitly_unverified
    with_runtime do |root, database|
      insert_owned_process(database, pid: 42_424)
      clock = ManualClock.new

      result = coordinator(
        root, database, timeout_sec: 0.1,
        capability: SequenceCapability.new(eligible, eligible),
        process_identity: FixedIdentity.new(:matching),
        monotonic: clock.method(:call), sleeper: clock.method(:sleep),
        signaler: ->(*) { raise Errno::EPERM }
      ).call

      refute result.paused
      assert_equal "signal_permission_denied",
                   result.remaining.first.fetch("unknown_reason")
    end
  end

  def test_unobservable_cgroup_member_remains_in_unresolved_inventory
    with_runtime do |root, database|
      insert_owned_process(
        database, pid: 42_424, custody_mode: "delegated_cgroup_v2",
        custody_path: "/hive/installation"
      )
      clock = ManualClock.new
      identity = MappedIdentity.new(42_424 => :missing)
      identity.define_singleton_method(:capture) { |_pid| nil }
      custody = Object.new
      custody.define_singleton_method(:members) { |_path, timeout_sec:| [ 42_425 ] }

      result = coordinator(
        root, database, timeout_sec: 0.1,
        capability: SequenceCapability.new(eligible, eligible),
        process_identity: identity, custody: custody,
        monotonic: clock.method(:call), sleeper: clock.method(:sleep)
      ).call

      refute result.paused
      assert_equal "timeout", result.reason
      descendant = result.remaining.first.fetch("descendants").fetch(0)
      assert_equal 42_425, descendant.fetch("pid")
      assert_equal "process_identity_unavailable", descendant.fetch("unknown_reason")
    end
  end

  def test_unobservable_cgroup_member_clears_only_after_frozen_inventory_proves_absence
    with_runtime do |root, database|
      insert_owned_process(
        database, pid: 42_424, custody_mode: "delegated_cgroup_v2",
        custody_path: "/hive/installation"
      )
      identity = MappedIdentity.new(42_424 => :missing)
      identity.define_singleton_method(:capture) { |_pid| nil }
      custody = Object.new
      inventories = [ [ 42_425 ], [] ]
      custody.define_singleton_method(:members) do |_path, timeout_sec:|
        inventories.shift || []
      end

      result = coordinator(
        root, database, capability: SequenceCapability.new(eligible, eligible),
        process_identity: identity, custody: custody
      ).call

      assert result.paused
      assert_empty result.remaining
    end
  end

  def test_checkpoint_busy_reverts_candidate_to_quiescing
    with_runtime do |root, database|
      database.define_singleton_method(:checkpoint!) do |timeout_sec:|
        { complete: false, busy: 1, log_frames: 3, checkpointed_frames: 1 }
      end

      result = coordinator(
        root, database,
        capability: SequenceCapability.new(eligible, eligible)
      ).call

      refute result.paused
      assert_equal "checkpoint_busy", result.reason
      assert_equal "quiescing", lifecycle(database).phase
      refute File.exist?(Hive::Paths.runtime_quiescence_proof_path(root))
    end
  end

  def test_checkpoint_error_reverts_candidate_to_quiescing
    with_runtime do |root, database|
      database.define_singleton_method(:checkpoint!) { |timeout_sec:| raise IOError, "forced checkpoint" }

      result = coordinator(
        root, database,
        capability: SequenceCapability.new(eligible, eligible)
      ).call

      refute result.paused
      assert_equal "checkpoint_error", result.reason
      assert_equal "quiescing", lifecycle(database).phase
      assert_match(/forced checkpoint/, result.details.fetch("error"))
    end
  end

  def test_proof_publication_failure_reverts_candidate_and_mismatch_is_rejected
    with_runtime do |root, database|
      broken_proof = Object.new
      broken_proof.define_singleton_method(:publish!) { |**| raise IOError, "forced proof crash" }
      broken_proof.define_singleton_method(:remove!) { true }

      result = coordinator(
        root, database, proof_store: broken_proof,
        capability: SequenceCapability.new(eligible, eligible)
      ).call

      refute result.paused
      assert_equal "proof_publication_failed", result.reason
      database.open!
      assert_equal "quiescing", lifecycle(database).phase

      good = Hive::Daemon::FinalizationProof.new(state_home: root)
      state = lifecycle(database)
      good.publish!(
        lifecycle: state, installation_id: "wrong-installation",
        checkpoint: {
          complete: true, busy: 0, log_frames: 0, checkpointed_frames: 0
        },
        interrupted_attempt_ids: [], inventory: [], published_at: Time.utc(2026, 9, 25)
      )
      verdict = good.verify(
        lifecycle: state,
        installation_id: database.installation_identity.fetch(:installation_id)
      )
      refute verdict.valid?
      assert_equal "installation_mismatch", verdict.reason
    end
  end

  def test_proof_directory_sync_failure_removes_unacknowledged_proof
    with_runtime do |root, database|
      writer = Object.new
      writer.define_singleton_method(:write) do |*args, **kwargs|
        Hive::AtomicFile.write(*args, **kwargs)
      end
      writer.define_singleton_method(:fsync_directory) { |_path| raise IOError, "forced sync" }
      proof = Hive::Daemon::FinalizationProof.new(state_home: root, writer: writer)

      result = coordinator(
        root, database, proof_store: proof,
        capability: SequenceCapability.new(eligible, eligible)
      ).call

      refute result.paused
      assert_equal "proof_publication_failed", result.reason
      refute File.exist?(Hive::Paths.runtime_quiescence_proof_path(root))
      assert_equal "quiescing", lifecycle(database).phase
    end
  end

  def test_proof_publication_must_finish_before_the_single_deadline
    with_runtime do |root, database|
      clock = ManualClock.new
      real = Hive::Daemon::FinalizationProof.new(state_home: root)
      slow = Object.new
      slow.define_singleton_method(:verify) { |**kwargs| real.verify(**kwargs) }
      slow.define_singleton_method(:remove!) { real.remove! }
      slow.define_singleton_method(:publish!) do |**kwargs|
        payload = real.publish!(**kwargs)
        clock.sleep(1)
        payload
      end

      result = coordinator(
        root, database, timeout_sec: 1, proof_store: slow,
        capability: SequenceCapability.new(eligible, eligible, eligible),
        monotonic: clock.method(:call), sleeper: clock.method(:sleep)
      ).call

      refute result.paused
      assert_equal "deadline_exhausted", result.reason
      refute File.exist?(Hive::Paths.runtime_quiescence_proof_path(root))
      assert_equal "quiescing", lifecycle(database).phase
    end
  end

  def test_retry_after_checkpoint_failure_reuses_generation
    with_runtime do |root, database|
      original = Hive::RuntimeControlPlane::Database.instance_method(:checkpoint!)
      database.define_singleton_method(:checkpoint!) do |timeout_sec:|
        { complete: false, busy: 1, log_frames: 1, checkpointed_frames: 0 }
      end
      capability = SequenceCapability.new(eligible, eligible, eligible, eligible)
      first = coordinator(root, database, capability: capability).call
      assert_equal "checkpoint_busy", first.reason

      database.define_singleton_method(:checkpoint!) do |timeout_sec:|
        original.bind_call(self, timeout_sec: timeout_sec)
      end
      second = coordinator(root, database, capability: capability).call

      assert second.paused
      assert_equal first.generation, second.generation
      assert_equal 1, second.generation
    end
  end

  def test_retry_after_boot_change_rebinds_the_same_closed_generation
    with_runtime do |root, database|
      closed = Hive::RuntimeControlPlane::LifecycleRepository.new(
        database: database
      ).begin_quiesce!(
        deadline_monotonic: 50, boot_id: "previous-boot", shutdown_grace_sec: 5
      )

      result = coordinator(
        root, database,
        capability: SequenceCapability.new(eligible, eligible)
      ).call

      assert result.paused
      assert_equal closed.generation, result.generation
      database.open!
      rebound = lifecycle(database)
      assert_equal "boot-test", rebound.boot_id
      assert_equal closed.generation, rebound.generation
    end
  end

  def test_retry_cancels_abandoned_preclose_reservation_before_entry_gate
    with_runtime do |root, database|
      registry = Hive::RuntimeControlPlane::ProcessRegistry.new(
        database: database, state_home: root
      )
      reservation = registry.reserve!(origin: "direct_cli", role: "command")
      closed = Hive::RuntimeControlPlane::LifecycleRepository.new(
        database: database
      ).begin_quiesce!(
        deadline_monotonic: 50, boot_id: "boot-test", shutdown_grace_sec: 5
      )
      reservation.release_fence!

      result = coordinator(
        root, database,
        capability: Hive::RuntimeControlPlane::QuiescenceCapability.new(
          database: database, state_home: root, legacy_inventory: -> { [] }
        )
      ).call

      assert result.paused
      assert_equal closed.generation, result.generation
      database.open!
      assert_equal "cancelled_by_quiesce",
                   database.read { |db| db[:launch_reservations].get(:state) }
    ensure
      reservation&.release_fence!
    end
  end

  def test_writer_fence_contention_is_not_reported_as_launch_fence_contention
    with_runtime do |root, database|
      database.define_singleton_method(:with_exclusive_writer) do |**|
        raise Hive::ConcurrentRunError.new("writer busy", lock_path: "/writer")
      end

      result = coordinator(
        root, database, capability: SequenceCapability.new(eligible)
      ).call

      assert_equal "writer_drain_timeout", result.reason
      refute_equal "launch_fence_busy", result.reason
      refute result.admission_open
    end
  end

  def test_rebinding_a_stale_quiescing_clock_reports_writer_fence_contention
    with_runtime do |root, database|
      Hive::RuntimeControlPlane::LifecycleRepository.new(database: database).begin_quiesce!(
        deadline_monotonic: 200, boot_id: "old-boot", shutdown_grace_sec: 25
      )
      database.define_singleton_method(:with_exclusive_writer) do |**|
        raise Hive::ConcurrentRunError.new("writer busy", lock_path: "/writer")
      end

      result = coordinator(
        root, database, capability: SequenceCapability.new(eligible)
      ).call

      assert_equal "writer_drain_timeout", result.reason
      refute result.admission_open
      assert_equal "quiescing", lifecycle(database).phase
    end
  end

  def test_attempt_repository_failure_returns_a_closed_admission_envelope
    with_runtime do |root, database|
      controller = coordinator(
        root, database, capability: SequenceCapability.new(eligible, eligible)
      )
      controller.define_singleton_method(:finalize_stopped_processes_and_attempts) do |**|
        raise Hive::Attempts::RepositoryError, "busy"
      end

      result = controller.call

      assert_equal "storage_error", result.reason
      refute result.admission_open
      assert_equal 1, result.generation
    end
  end

  def test_retry_revalidates_a_paused_candidate_missing_its_proof
    with_runtime do |root, database|
      repository = Hive::RuntimeControlPlane::LifecycleRepository.new(database: database)
      quiescing = repository.begin_quiesce!(
        deadline_monotonic: 200, boot_id: "boot-test", shutdown_grace_sec: 25
      )
      paused = nil
      database.with_exclusive_writer(role: :controller, timeout_sec: 1) do |authority|
        paused = repository.mark_paused!(
          generation: quiescing.generation, expected_revision: quiescing.revision,
          interrupted_attempt_ids: [], authority: authority
        )
      end
      refute File.exist?(Hive::Paths.runtime_quiescence_proof_path(root))

      result = coordinator(
        root, database,
        capability: SequenceCapability.new(eligible, eligible, eligible)
      ).call

      assert result.paused
      assert_equal paused.generation, result.generation
      assert_operator result.lifecycle_revision, :>, paused.revision
      assert File.file?(Hive::Paths.runtime_quiescence_proof_path(root))
    end
  end

  private

  def coordinator(root, database, timeout_sec: 1, capability:, **options)
    Hive::Daemon::Quiescence.new(
      state_home: root, database: database, timeout_sec: timeout_sec,
      capability: capability, boot_id_reader: -> { "boot-test" }, **options
    )
  end

  def lifecycle(database)
    database.open! if database.disconnected?
    Hive::RuntimeControlPlane::LifecycleRepository.new(database: database).current
  end

  def eligible
    Hive::RuntimeControlPlane::CapabilityVerdict.new(
      eligible: true, reason: nil, ownership_mode: "registered_only",
      disqualifying_inventory: []
    )
  end

  def refusal(reason)
    Hive::RuntimeControlPlane::CapabilityVerdict.new(
      eligible: false, reason: reason, ownership_mode: "unverified",
      disqualifying_inventory: [ { "attempt_id" => "attempt-1" } ]
    )
  end

  def insert_owned_process(database, pid:, custody_mode: "unverified", custody_path: nil)
    now = Time.now.utc.iso8601(6)
    database.transaction do |db|
      installation_id = db[:installations].get(:installation_id)
      db[:launch_reservations].insert(
        reservation_id: "reservation-#{pid}", installation_id: installation_id,
        origin: "safe_fixture", role: "service", state: "registered",
        admission_generation: 0, owner_pid: pid,
        owner_start_fingerprint: "start-#{pid}", created_at: now, updated_at: now
      )
      db[:owned_processes].insert(
        process_id: "process-#{pid}", installation_id: installation_id,
        reservation_id: "reservation-#{pid}", origin: "safe_fixture", role: "service",
        pid: pid, start_fingerprint: "start-#{pid}", process_group_id: pid,
        session_id: pid, state: "running", proven_child_safe: 1,
        custody_mode: custody_mode, custody_path: custody_path,
        custody_evidence_json: "{}",
        created_at: now, updated_at: now
      )
    end
  end

  def with_runtime
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(root)
      ).migrate!
      yield root, database
    ensure
      database&.disconnect
    end
  end
end
