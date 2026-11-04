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

  def test_adopt_rejects_unavailable_or_mismatched_child_identity
    unavailable = Object.new
    unavailable.define_singleton_method(:capture) { |_pid| nil }
    with_registry(process_identity: unavailable) do |_database, registry, _root|
      error = assert_raises(Hive::RuntimeControlPlane::Unavailable) do
        registry.adopt!("missing-reservation", pid: Process.pid)
      end
      assert_equal :process_identity_unavailable, error.code
    end

    identities = [
      Hive::Attempts::ProcessSnapshot.new(
        pid: 100, start_fingerprint: "owner", session_id: 100, process_group_id: 100
      ),
      Hive::Attempts::ProcessSnapshot.new(
        pid: 101, start_fingerprint: "registered", session_id: 101, process_group_id: 101
      ),
      Hive::Attempts::ProcessSnapshot.new(
        pid: 102, start_fingerprint: "adopting", session_id: 102, process_group_id: 102
      )
    ]
    process_identity = Object.new
    process_identity.define_singleton_method(:capture) { |_pid| identities.shift }
    with_registry(process_identity: process_identity) do |_database, registry, _root|
      reservation = registry.reserve!(origin: "daemon_child", role: "command", owner_pid: 100)
      registry.register!(reservation.id, pid: 101)

      assert_raises(Hive::RuntimeControlPlane::StaleLifecycle) do
        registry.adopt!(reservation.id, pid: 102)
      end
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

  def test_attempt_wrapper_cleanup_retains_descendant_ownership_across_registry_restart
    descendant_pid = Process.pid + 100_000
    members = [ Process.pid, descendant_pid ]
    custody = Object.new
    custody.define_singleton_method(:evidence_for) do |_pid|
      { "eligible" => true, "mode" => "delegated_cgroup_v2", "path" => "/hive/install" }
    end
    custody.define_singleton_method(:verifiable?) { |_row| true }
    custody.define_singleton_method(:members) { |_path, timeout_sec: nil| members }

    with_registry do |database, _registry, root|
      registry = Hive::RuntimeControlPlane::ProcessRegistry.new(
        database: database, state_home: root, custody: custody
      )
      reservation = registry.reserve!(
        origin: "attempt", role: "attempt_wrapper", attempt_id: "attempt-1"
      )
      registry.register!(reservation.id, pid: Process.pid)
      reservation.release_fence!

      registry.mark_stopped_by_reservation!(
        reservation.id, require_descendant_absence: true
      )
      restarted = Hive::RuntimeControlPlane::ProcessRegistry.new(
        database: database, state_home: root, custody: custody
      )
      retained = restarted.active_rows.fetch(0)
      assert_equal "running", retained.fetch(:state)
      assert_equal "descendant_absence_unverified", retained.fetch(:unknown_reason)

      members.clear
      missing_identity = Object.new
      missing_identity.define_singleton_method(:status) { |_identity| :missing }
      stopped_registry = Hive::RuntimeControlPlane::ProcessRegistry.new(
        database: database, state_home: root, custody: custody,
        process_identity: missing_identity
      )
      stopped_registry.mark_stopped_by_reservation!(
        reservation.id, require_descendant_absence: true
      )
      assert_empty stopped_registry.active_rows
    ensure
      reservation&.release_fence!
    end
  end

  def test_unreadable_legacy_process_identity_cannot_look_like_an_idle_registry
    identity = Object.new
    identity.define_singleton_method(:capture) { |_pid| nil }
    identity.define_singleton_method(:status) { |_value| :absent }
    with_registry(process_identity: identity) do |database, _registry, root|
      File.write(File.join(root, ".daemon.pid"), { "pid" => Process.pid }.to_yaml)

      verdict = Hive::RuntimeControlPlane::QuiescenceCapability.new(
        database: database, state_home: root, process_identity: identity,
        custody: Hive::Attempts::ProcessCustody.unsupported("test")
      ).call

      refute verdict.eligible?
      assert_equal "legacy_process_unregistered", verdict.reason
      assert_equal "pid_ownership_unverified",
                   verdict.disqualifying_inventory.first.fetch("unknown_reason")
    end
  end

  def test_stale_and_reused_legacy_pid_receipts_do_not_block_quiescence
    with_registry do |database, _registry, root|
      File.write(File.join(root, ".daemon.pid"), {
        "pid" => 999_999_999, "process_start_time" => "dead"
      }.to_yaml)
      File.write(File.join(root, ".bot.pid"), {
        "pid" => Process.pid, "process_start_time" => "not-this-process"
      }.to_yaml)

      verdict = Hive::RuntimeControlPlane::QuiescenceCapability.new(
        database: database, state_home: root,
        custody: Hive::Attempts::ProcessCustody.unsupported("test")
      ).call

      assert verdict.eligible?, verdict.to_h.inspect
    end
  end

  def test_persisted_legacy_bot_identity_disqualifies_quiescence
    with_registry do |database, _registry, root|
      File.write(File.join(root, ".bot.pid"), {
        "pid" => Process.pid,
        "process_start_time" => Hive::Lock.process_start_time(Process.pid)
      }.to_yaml)

      verdict = Hive::RuntimeControlPlane::QuiescenceCapability.new(
        database: database, state_home: root,
        custody: Hive::Attempts::ProcessCustody.unsupported("test")
      ).call

      refute verdict.eligible?
      assert_equal "legacy_process_unregistered", verdict.reason
      assert_equal ".bot.pid",
                   verdict.disqualifying_inventory.first.fetch("service_identity")
      assert_equal Process.pid, verdict.disqualifying_inventory.first.fetch("pid")
    end
  end

  def test_absence_checks_fail_closed_when_custody_or_legacy_receipts_cannot_be_read
    custody = Object.new
    custody.define_singleton_method(:verifiable?) { |_row| true }
    custody.define_singleton_method(:members) { |_path| raise IOError, "unavailable" }
    missing_identity = Object.new
    missing_identity.define_singleton_method(:status) { |_row| :missing }
    with_registry(process_identity: missing_identity) do |database, registry, root|
      row = { pid: Process.pid, start_fingerprint: "old", session_id: Process.pid,
              process_group_id: Process.pid, custody_path: "/hive/test" }
      guarded_registry = Hive::RuntimeControlPlane::ProcessRegistry.new(
        database: database, state_home: root, process_identity: missing_identity, custody: custody
      )
      refute guarded_registry.descendant_absence_verified?(row)

      capability = Hive::RuntimeControlPlane::QuiescenceCapability.new(
        database: database, state_home: root, process_identity: missing_identity, custody: custody
      )
      refute capability.send(:safely_absent?, row)

      File.write(File.join(root, ".daemon.pid"), "---\n: [\n")
      legacy = capability.send(:known_legacy_processes)
      assert_equal "pid_receipt_unreadable", legacy.first.fetch("unknown_reason")
    end
  end

  def test_unreadable_legacy_pid_receipt_is_reported_as_unknown
    with_registry do |database, _registry, root|
      receipt = File.join(root, ".daemon.pid")
      File.write(receipt, { "pid" => Process.pid }.to_yaml)
      original_file_read = File.method(:read)

      capability = Hive::RuntimeControlPlane::QuiescenceCapability.new(
        database: database, state_home: root,
        custody: Hive::Attempts::ProcessCustody.unsupported("test")
      )

      with_replaced_singleton_method(File, :read, lambda { |path, *args|
        raise IOError, "receipt vanished during read" if path == receipt

        original_file_read.call(path, *args)
      }) do
        legacy = capability.send(:known_legacy_processes)

        assert_equal [ {
          "service_identity" => ".daemon.pid", "pid" => nil,
          "unknown_reason" => "pid_receipt_unreadable"
        } ], legacy
      end
    end
  end

  def test_capability_ignores_the_retired_hivebox_supervisor_environment
    process_identity = Object.new
    process_identity.define_singleton_method(:capture) { |_pid| raise "must not probe the retired supervisor" }
    with_registry(process_identity: process_identity) do |database, _registry, root|
      capability = Hive::RuntimeControlPlane::QuiescenceCapability.new(
        database: database, state_home: root, process_identity: process_identity,
        custody: Hive::Attempts::ProcessCustody.unsupported("test")
      )

      legacy = with_env("HIVEBOX_SUPERVISOR_PID" => "123") do
        capability.send(:known_legacy_processes)
      end

      assert_empty legacy
    end
  end

  class UnverifiableOwnerIdentity < SimpleDelegator
    def status(_expected) = :unverifiable
  end

  def test_reservations_of_gone_owners_are_released_and_live_owners_are_kept
    with_registry do |database, registry, _root|
      live = registry.reserve!(origin: "direct_cli", role: "status")
      dead = registry.reserve!(origin: "direct_cli", role: "status")
      reused = registry.reserve!(origin: "direct_cli", role: "revise")
      unrecorded = registry.reserve!(origin: "direct_cli", role: "status")
      [ live, dead, reused, unrecorded ].each(&:release_fence!)
      gone_pid = Process.spawn("true")
      Process.wait(gone_pid)
      database.transaction do |db|
        db[:launch_reservations].where(reservation_id: dead.id).update(owner_pid: gone_pid)
        db[:launch_reservations].where(reservation_id: reused.id)
          .update(owner_start_fingerprint: "not-this-process")
        db[:launch_reservations].where(reservation_id: unrecorded.id)
          .update(owner_pid: nil, owner_start_fingerprint: nil)
      end

      released = registry.release_abandoned_reservations!
      assert_equal [ dead.id, reused.id ].sort, released.map { |r| r["reservation_id"] }.sort
      assert_equal [ "owner_gone" ], released.map { |r| r["reason"] }.uniq
      states = database.read { |db| db[:launch_reservations].to_hash(:reservation_id, :state) }
      assert_equal "reserved", states.fetch(live.id)
      assert_equal "reserved", states.fetch(unrecorded.id)
      assert_equal "released", states.fetch(dead.id)
      assert_equal "released", states.fetch(reused.id)
      assert_empty registry.release_abandoned_reservations!

      assert_raises(Hive::RuntimeControlPlane::StaleLifecycle) do
        registry.register!(dead.id, pid: Process.pid)
      end
    end
  end

  def test_an_unverifiable_owner_keeps_its_reservation
    identity = UnverifiableOwnerIdentity.new(Hive::Attempts::ProcessIdentity.new)
    with_registry(process_identity: identity) do |database, registry, _root|
      reservation = registry.reserve!(origin: "direct_cli", role: "status")
      reservation.release_fence!
      database.transaction do |db|
        db[:launch_reservations].update(owner_start_fingerprint: "not-this-process")
      end
      assert_empty registry.release_abandoned_reservations!
      assert_equal "reserved", database.read { |db| db[:launch_reservations].get(:state) }
    end
  end

  def test_reservation_of_a_settled_attempt_is_released_as_attempt_settled
    with_registry do |database, registry, _root|
      insert_attempt(database, "attempt-lost", state: "lost")
      reservation = registry.reserve!(origin: "attempt", role: "attempt_wrapper", attempt_id: "attempt-lost")
      reservation.release_fence!

      assert_equal [ { "reservation_id" => reservation.id, "reason" => "attempt_settled" } ],
                   registry.release_abandoned_reservations!
      assert_equal "released", database.read { |db| db[:launch_reservations].get(:state) }
    end
  end

  def test_reservation_of_a_live_attempt_is_kept_even_when_its_launcher_died
    with_registry do |database, registry, _root|
      insert_attempt(database, "attempt-launching", state: "launching")
      insert_attempt(database, "attempt-running", state: "running")
      reservations = %w[attempt-launching attempt-running].map do |attempt_id|
        registry.reserve!(origin: "attempt", role: "attempt_wrapper", attempt_id: attempt_id)
      end
      reservations.each(&:release_fence!)
      gone_pid = Process.spawn("true")
      Process.wait(gone_pid)
      database.transaction { |db| db[:launch_reservations].update(owner_pid: gone_pid) }

      assert_empty registry.release_abandoned_reservations!
      assert_equal %w[reserved reserved], database.read { |db| db[:launch_reservations].select_map(:state) }
    end
  end

  def test_reservation_without_an_attempt_row_falls_through_to_the_owner_check
    with_registry do |database, registry, _root|
      live = registry.reserve!(origin: "attempt", role: "attempt_wrapper", attempt_id: "attempt-unknown-live")
      dead = registry.reserve!(origin: "attempt", role: "attempt_wrapper", attempt_id: "attempt-unknown-dead")
      [ live, dead ].each(&:release_fence!)
      gone_pid = Process.spawn("true")
      Process.wait(gone_pid)
      database.transaction do |db|
        db[:launch_reservations].where(reservation_id: dead.id).update(owner_pid: gone_pid)
      end

      assert_equal [ { "reservation_id" => dead.id, "reason" => "owner_gone" } ],
                   registry.release_abandoned_reservations!
      states = database.read { |db| db[:launch_reservations].to_hash(:reservation_id, :state) }
      assert_equal "reserved", states.fetch(live.id)
    end
  end

  def test_capability_becomes_eligible_once_abandoned_reservations_are_released
    with_registry do |database, registry, root|
      capability = Hive::RuntimeControlPlane::QuiescenceCapability.new(
        database: database, state_home: root,
        legacy_inventory: -> { [] }, custody: Hive::Attempts::ProcessCustody.unsupported("test")
      )
      reservation = registry.reserve!(origin: "direct_cli", role: "status")
      reservation.release_fence!
      gone_pid = Process.spawn("true")
      Process.wait(gone_pid)
      database.transaction { |db| db[:launch_reservations].update(owner_pid: gone_pid) }
      refusal = capability.call
      refute refusal.eligible?
      assert_equal "unresolved_launch_reservation", refusal.reason

      registry.release_abandoned_reservations!
      assert capability.call.eligible?
    end
  end

  private

  def insert_attempt(database, attempt_id, state:)
    now = "2026-11-04T00:00:00.000000Z"
    identity = database.read { |db| db[:runtime_lifecycle].get(:installation_id) }
    database.transaction do |db|
      unless db[:projects].where(project_id: "project-1").first
        db[:projects].insert(
          project_id: "project-1", installation_id: identity, registration_id: "registration-1",
          name: "demo", observed_path: "/tmp/demo", state_root_path: "/tmp/demo/.hive-state",
          active: 1, registered_at: now
        )
      end
      task_id = "task-#{attempt_id}"
      db[:task_subjects].insert(
        task_id: task_id, project_id: "project-1", workflow_id: "coding",
        task_slug: task_id, observed_path: "/tmp/demo/#{task_id}", source_fingerprint: "source",
        generation: 1, created_at: now, last_observed_at: now
      )
      db[:attempts].insert(
        attempt_id: attempt_id, project_id: "project-1", task_id: task_id,
        subject_kind: "task_stage", subject_key: "4-execute", subject_json: "{}",
        task_generation: "generation-#{attempt_id}", ownership_generation: "owner-1", state: state,
        lease_version: 0, retry_charge: 0, refunded: 0, source_fingerprint: "source",
        details_json: "{}", project_name: "demo", task_slug: task_id,
        accepted_date: "2026-11-04", created_at: now, accepted_at: now
      )
    end
  end

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
