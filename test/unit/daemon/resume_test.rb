require "test_helper"
require "hive/daemon/quiescence"
require "hive/daemon/status_report"

class HiveDaemonResumeTest < Minitest::Test
  include HiveTestHelper

  class EligibleCapability
    def call
      Hive::RuntimeControlPlane::CapabilityVerdict.new(
        eligible: true, reason: nil, ownership_mode: "registered_only",
        disqualifying_inventory: []
      )
    end
  end

  class FixedProcessIdentity
    def initialize(status = nil, error: nil)
      @status = status
      @error = error
    end

    def status(_identity)
      raise @error if @error

      @status
    end
  end

  def test_resume_removes_proof_reconciles_and_reopens_the_same_generation
    with_runtime do |root, database|
      paused = Hive::Daemon::Quiescence.new(
        state_home: root, database: database, capability: EligibleCapability.new,
        timeout_sec: 1, boot_id_reader: -> { "boot-test" }
      ).call
      assert paused.paused
      proof_events = []
      proof = Hive::Daemon::FinalizationProof.new(state_home: root)
      proof_store = Object.new
      proof_store.define_singleton_method(:remove!) do
        current = Hive::RuntimeControlPlane::LifecycleRepository.new(
          database: database
        ).current
        proof_events << [ current.phase, current.revision ]
        proof.remove!
      end

      result = Hive::Daemon::Resume.new(
        state_home: root, database: database, timeout_sec: 1,
        proof_store: proof_store
      ).call

      assert result.resumed
      assert result.admission_reopened
      assert_equal paused.generation, result.generation
      assert_equal "running", result.phase
      assert_equal [ [ "paused", paused.lifecycle_revision ] ], proof_events
      refute File.exist?(Hive::Paths.runtime_quiescence_proof_path(root))
      assert Hive::RuntimeControlPlane::LifecycleRepository.new(database: database).current.admission_open?
    end
  end

  def test_service_failure_is_reported_after_admission_reopens_and_retry_is_idempotent
    with_runtime do |root, database|
      insert_quiesced_service(database, "hive-web")
      lifecycle = Hive::RuntimeControlPlane::LifecycleRepository.new(database: database)
      closed = lifecycle.begin_quiesce!(
        deadline_monotonic: 200, boot_id: "boot-test", shutdown_grace_sec: 25
      )
      calls = 0
      restorer = lambda do |service_identity:, timeout_sec:|
        calls += 1
        { "service_identity" => service_identity, "ok" => calls > 1,
          "reason" => calls > 1 ? nil : "start_failed" }
      end

      first = Hive::Daemon::Resume.new(
        state_home: root, database: database, timeout_sec: 1,
        service_restorer: restorer
      ).call
      second = Hive::Daemon::Resume.new(
        state_home: root, database: database, timeout_sec: 1,
        service_restorer: restorer
      ).call

      assert first.admission_reopened
      refute first.resumed
      assert_equal "service_restore_failed", first.reason
      assert second.resumed
      assert_equal closed.generation, second.generation
      assert_equal 2, calls
    end
  end

  def test_busy_controller_does_not_mutate_open_admission
    with_runtime do |root, database|
      lock = Object.new
      lock.define_singleton_method(:synchronize) do
        raise Hive::ConcurrentRunError.new("busy", lock_path: "/operation")
      end

      result = Hive::Daemon::Resume.new(
        state_home: root, database: database,
        operation_lock_factory: ->(_timeout) { lock }
      ).call

      refute result.resumed
      assert_equal "controller_busy", result.reason
      assert result.admission_open
      assert_equal "running", lifecycle(database).phase
    end
  end

  def test_failure_after_proof_removal_keeps_admission_closed_and_status_unpaused
    with_runtime do |root, database|
      paused = Hive::Daemon::Quiescence.new(
        state_home: root, database: database, capability: EligibleCapability.new,
        timeout_sec: 1, boot_id_reader: -> { "boot-test" }
      ).call
      repository = Hive::RuntimeControlPlane::LifecycleRepository.new(database: database)
      lifecycle = Object.new
      lifecycle.define_singleton_method(:current) { repository.current }
      lifecycle.define_singleton_method(:begin_resume!) do |**|
        raise Hive::RuntimeControlPlane::IntegrityError.new(
          "injected failure", code: :injected_resume_failure
        )
      end

      result = Hive::Daemon::Resume.new(
        state_home: root, database: database, lifecycle: lifecycle, timeout_sec: 1
      ).call

      assert_equal "storage_error", result.reason
      refute result.admission_open
      refute_path_exists Hive::Paths.runtime_quiescence_proof_path(root)
      assert_equal "paused", repository.current.phase

      report = Hive::Daemon::StatusReport.new(hive_home: root, environment: {})
      report.define_singleton_method(:probe_service_state) do
        {
          "service_installed" => false, "service_enabled" => false,
          "unit_path" => nil, "installed_binary" => nil, "expected_binary" => nil
        }
      end
      report.define_singleton_method(:update_nudge_payload) { nil }
      assert_equal "quiescing", report.payload.dig("lifecycle", "phase")
      assert paused.paused
    end
  end

  def test_live_owned_process_keeps_admission_closed_after_resume_reconciliation
    with_runtime do |root, database|
      insert_active_process(database)
      closed = Hive::RuntimeControlPlane::LifecycleRepository.new(
        database: database
      ).begin_quiesce!(
        deadline_monotonic: 200, boot_id: "boot-test", shutdown_grace_sec: 25
      )

      result = Hive::Daemon::Resume.new(
        state_home: root, database: database, timeout_sec: 1,
        process_identity: FixedProcessIdentity.new(:matching)
      ).call

      refute result.resumed
      refute result.admission_open
      refute result.admission_reopened
      assert_equal "reconciliation_incomplete", result.reason
      assert_equal closed.generation, result.generation
      assert_equal "owned_process_alive", result.remaining.first.fetch("unknown_reason")
      assert_equal "resuming", lifecycle(database).phase
    end
  end

  def test_unprobeable_owned_process_keeps_admission_closed
    with_runtime do |root, database|
      insert_active_process(database)
      Hive::RuntimeControlPlane::LifecycleRepository.new(database: database).begin_quiesce!(
        deadline_monotonic: 200, boot_id: "boot-test", shutdown_grace_sec: 25
      )

      result = Hive::Daemon::Resume.new(
        state_home: root, database: database, timeout_sec: 1,
        process_identity: FixedProcessIdentity.new(error: Errno::EPERM.new("denied"))
      ).call

      assert_equal "reconciliation_incomplete", result.reason
      refute result.admission_reopened
      assert_equal "process_identity_probe_failed:Errno::EPERM",
                   result.remaining.first.fetch("unknown_reason")
      assert_equal "resuming", lifecycle(database).phase
    end
  end

  def test_service_restore_is_bounded_after_admission_reopens
    with_runtime do |root, database|
      insert_quiesced_service(database, "hive-web")
      Hive::RuntimeControlPlane::LifecycleRepository.new(database: database).begin_quiesce!(
        deadline_monotonic: 200, boot_id: "boot-test", shutdown_grace_sec: 25
      )

      result = Hive::Daemon::Resume.new(
        state_home: root, database: database, timeout_sec: 0.1,
        service_restorer: ->(**) { sleep 1 }
      ).call

      refute result.resumed
      assert result.admission_reopened
      assert result.admission_open
      assert_equal "deadline_exhausted", result.reason
      assert_equal "deadline_exhausted", result.services.first.fetch("reason")
      assert_equal "running", lifecycle(database).phase
    end
  end

  def test_attempt_reconciliation_finishes_before_admission_reopens
    with_runtime do |root, database|
      repository = Hive::RuntimeControlPlane::LifecycleRepository.new(database: database)
      repository.begin_quiesce!(
        deadline_monotonic: 200, boot_id: "boot-test", shutdown_grace_sec: 25
      )
      attempt = Struct.new(:attempt_id, :state).new("attempt-1", "running")
      store = Object.new
      store.define_singleton_method(:active_attempts) { [ attempt ] }
      observed_phases = []
      reconciler = Object.new
      reconciler.define_singleton_method(:finalize_interruption) do |record, **|
        observed_phases << repository.current.phase
        Struct.new(:classification, :attempt).new(:terminal, record)
      end
      reconciler.define_singleton_method(:reconcile) do |**|
        observed_phases << repository.current.phase
        Struct.new(:attempts).new([])
      end

      result = Hive::Daemon::Resume.new(
        state_home: root, database: database, timeout_sec: 1,
        attempt_store: store, reconciler: reconciler
      ).call

      assert result.resumed
      assert_equal [ "resuming", "resuming" ], observed_phases
      assert_equal [ "attempt-1" ], result.reconciled_attempt_ids
      assert_equal "running", repository.current.phase
    end
  end

  private

  def insert_quiesced_service(database, identity)
    now = Time.now.utc.iso8601(6)
    database.transaction do |db|
      installation_id = db[:installations].get(:installation_id)
      db[:owned_processes].insert(
        process_id: "service-process", installation_id: installation_id,
        service_identity: identity, origin: "safe_fixture", role: "service",
        state: "stopped", proven_child_safe: 1, custody_mode: "unverified",
        unknown_reason: "quiesced", created_at: now, updated_at: now, stopped_at: now
      )
    end
  end

  def insert_active_process(database)
    now = Time.now.utc.iso8601(6)
    database.transaction do |db|
      installation_id = db[:installations].get(:installation_id)
      db[:owned_processes].insert(
        process_id: "active-process", installation_id: installation_id,
        origin: "safe_fixture", role: "service", pid: 123_456,
        start_fingerprint: "fixture-start", state: "running",
        proven_child_safe: 1, custody_mode: "unverified",
        created_at: now, updated_at: now
      )
    end
  end

  def lifecycle(database)
    Hive::RuntimeControlPlane::LifecycleRepository.new(database: database).current
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
