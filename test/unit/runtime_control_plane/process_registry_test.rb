require "test_helper"
require "hive/attempts/process_custody"
require "hive/runtime_control_plane/lifecycle_repository"
require "hive/runtime_control_plane/process_registry"

class RuntimeControlPlaneProcessRegistryTest < Minitest::Test
  include HiveTestHelper

  def test_reservation_and_identity_registration_are_durable
    with_registry do |database, registry, _root|
      reservation = registry.reserve!(
        origin: "daemon_child", role: "command", task_id: "task-1"
      )
      process = registry.register!(
        reservation.id, pid: Process.pid, service_identity: "daemon-child",
        proven_child_safe: false
      )
      reservation.release_fence!

      observed = database.read do |db|
        [ db[:launch_reservations].first, db[:owned_processes].first ]
      end
      assert_equal "registered", observed.first.fetch(:state)
      assert_equal Process.pid, observed.last.fetch(:pid)
      assert_equal process.process_id, observed.last.fetch(:process_id)
      refute_empty observed.last.fetch(:start_fingerprint)
    end
  end

  def test_preclose_reservation_handshake_is_denied_and_controller_cancels_it
    with_registry do |database, registry, _root|
      reservation = registry.reserve!(origin: "attempt", role: "attempt_wrapper", attempt_id: "a-1")
      lifecycle = Hive::RuntimeControlPlane::LifecycleRepository.new(database: database)
      state = lifecycle.begin_quiesce!(
        deadline_monotonic: 40, boot_id: "boot", shutdown_grace_sec: 10
      )

      error = assert_raises(Hive::RuntimeControlPlane::AdmissionClosed) do
        registry.register!(reservation.id, pid: Process.pid)
      end
      assert_equal state.generation, error.details.fetch(:generation)
      reservation.release_fence!

      database.with_exclusive_writer(role: :controller, timeout_sec: 1) do |authority|
        cancelled = registry.settle_preclose_reservations!(
          generation: state.generation, authority: authority
        )
        assert_equal [ reservation.id ], cancelled
      end
      row = database.read { |db| db[:launch_reservations].first }
      assert_equal "cancelled_by_quiesce", row.fetch(:state)
      assert_equal "quiescing", row.fetch(:reason)
    ensure
      reservation&.release_fence!
    end
  end

  def test_increment_one_capability_allows_only_idle_or_proven_child_safe_roots
    with_registry do |database, registry, root|
      capability = Hive::RuntimeControlPlane::QuiescenceCapability.new(
        database: database, state_home: root,
        legacy_inventory: -> { [] }, custody: Hive::Attempts::ProcessCustody.unsupported("test")
      )
      assert capability.call.eligible?

      reservation = registry.reserve!(origin: "web_supervisor", role: "web", task_id: nil)
      registry.register!(reservation.id, pid: Process.pid, proven_child_safe: false)
      reservation.release_fence!
      refusal = capability.call
      refute refusal.eligible?
      assert_equal "unproven_launch_surface", refusal.reason

      registry.mark_stopped_by_reservation!(reservation.id)
      safe = registry.reserve!(origin: "safe_fixture", role: "service", task_id: nil)
      registry.register!(safe.id, pid: Process.pid, proven_child_safe: true)
      safe.release_fence!
      refusal = capability.call
      refute refusal.eligible?
      assert_equal "unproven_launch_surface", refusal.reason
    ensure
      safe&.release_fence!
      reservation&.release_fence!
    end
  end

  def test_rebind_refreshes_identity_after_daemonize
    identities = [
      Hive::Attempts::ProcessSnapshot.new(
        pid: 100, start_fingerprint: "old", session_id: 100, process_group_id: 100
      ),
      Hive::Attempts::ProcessSnapshot.new(
        pid: 100, start_fingerprint: "old", session_id: 100, process_group_id: 100
      ),
      Hive::Attempts::ProcessSnapshot.new(
        pid: 200, start_fingerprint: "new", session_id: 200, process_group_id: 200
      )
    ]
    process_identity = Object.new
    process_identity.define_singleton_method(:capture) { |_pid| identities.shift }
    with_registry(process_identity: process_identity) do |database, registry, _root|
      reservation = registry.reserve!(origin: "direct_cli", role: "daemon")
      registry.register!(reservation.id, pid: 100)
      reservation.release_fence!

      rebound = registry.rebind!(reservation.id, pid: 200)

      assert_equal 200, rebound.pid
      row = database.read { |db| db[:owned_processes].first }
      assert_equal 200, row.fetch(:pid)
      assert_equal "new", row.fetch(:start_fingerprint)
    ensure
      reservation&.release_fence!
    end
  end

  def test_agent_attempt_root_is_unverifiable_without_delegated_custody
    with_registry do |database, registry, root|
      reservation = registry.reserve!(origin: "attempt", role: "attempt_wrapper", attempt_id: "a-1")
      registry.register!(reservation.id, pid: Process.pid)
      reservation.release_fence!

      verdict = Hive::RuntimeControlPlane::QuiescenceCapability.new(
        database: database, state_home: root, legacy_inventory: -> { [] },
        custody: Hive::Attempts::ProcessCustody.unsupported("no delegation")
      ).call
      refute verdict.eligible?
      assert_equal "agent_attempt_root", verdict.reason
      assert_equal "a-1", verdict.disqualifying_inventory.first.fetch("attempt_id")
    ensure
      reservation&.release_fence!
    end
  end

  def test_unreadable_legacy_process_identity_cannot_look_like_an_idle_registry
    identity = Object.new
    identity.define_singleton_method(:capture) { |_pid| nil }
    identity.define_singleton_method(:status) { |_value| :absent }
    with_registry(process_identity: identity) do |database, _registry, root|
      File.write(File.join(root, ".daemon.pid"), { "pid" => 99_999 }.to_yaml)

      verdict = Hive::RuntimeControlPlane::QuiescenceCapability.new(
        database: database, state_home: root, process_identity: identity,
        custody: Hive::Attempts::ProcessCustody.unsupported("test")
      ).call

      refute verdict.eligible?
      assert_equal "legacy_process_unregistered", verdict.reason
      assert_equal "process_identity_unavailable",
                   verdict.disqualifying_inventory.first.fetch("unknown_reason")
    end
  end

  private

  def with_registry(process_identity: Hive::Attempts::ProcessIdentity.new)
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(root)
      ).migrate!
      registry = Hive::RuntimeControlPlane::ProcessRegistry.new(
        database: database, state_home: root, process_identity: process_identity
      )
      yield database, registry, root
    ensure
      database&.disconnect
    end
  end
end
