require "test_helper"
require "hive/attempts/process_custody"
require "hive/attempts/bookkeeping_retry"
require "hive/runtime_control_plane/lifecycle_repository"
require "hive/runtime_control_plane/process_registry"

class RuntimeControlPlaneProcessRegistryTest < Minitest::Test
  include HiveTestHelper

  def test_reservation_fence_exhaustion_is_bounded_typed_tempfail_without_sql
    with_registry do |database, registry, root|
      fence = Hive::RuntimeControlPlane::LaunchFence.new(state_home: root, timeout_sec: 0.1)
      fence.acquire_exclusive!
      retries = Hive::Attempts::BookkeepingRetry.new(
        operation: "reserve_wrapper", attempt_id: "a-1", budget_sec: 0.15
      )
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = assert_raises(Hive::Attempts::BookkeepingBusy) do
        retries.run do |timeout|
          registry.reserve!(origin: "attempt", role: "attempt_wrapper", attempt_id: "a-1", timeout_sec: timeout)
        end
      end
      assert_equal Hive::ExitCodes::TEMPFAIL, error.exit_code
      assert_equal "runtime_bookkeeping_busy", error.reason
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.35
      assert_empty database.read { |db| db[:launch_reservations].all }
    ensure
      fence&.release!
    end
  end

  def test_reservation_sql_wait_uses_remaining_budget_and_restores_timeout
    with_registry do |database, registry, _root|
      holder = SQLite3::Database.new(database.path)
      holder.execute("BEGIN IMMEDIATE")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = assert_raises(Hive::RuntimeControlPlane::Busy) do
        registry.reserve!(origin: "attempt", role: "attempt_wrapper", timeout_sec: 0.08)
      end
      assert Hive::InternalError.sqlite_busy?(error)
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.25
      assert_equal Hive::RuntimeControlPlane::BUSY_TIMEOUT_MS,
                   database.read { |db| db.fetch("PRAGMA busy_timeout").get }
    ensure
      holder&.execute("ROLLBACK")
      holder&.close
    end
  end

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

  EMPTY_TABLE = Hive::Attempts::ProcessTableSnapshot.new(session_ids: Set.new, process_group_ids: Set.new)

  def test_exited_direct_cli_rows_are_closed_and_live_ones_are_kept
    with_registry(process_table: -> { EMPTY_TABLE }) do |database, registry, _root|
      live = register_process(registry, origin: "direct_cli", role: "status")
      gone_pid = spawn_gone_pid
      gone = register_process(registry, origin: "direct_cli", role: "brainstorm")
      reused = register_process(registry, origin: "direct_cli", role: "review")
      move_process(database, gone, pid: gone_pid, session_id: 7_001, process_group_id: 7_001)
      database.transaction do |db|
        db[:owned_processes].where(process_id: reused).update(start_fingerprint: "not-this-process")
      end

      closed = registry.reconcile_exited_processes!
      assert_equal [ gone, reused ].sort, closed.map { |row| row["process_id"] }.sort
      assert_equal [ "owner_gone_custody_unverified" ], closed.map { |row| row["reason"] }.uniq
      assert_equal [ "root_gone" ], closed.map { |row| row["evidence"] }.uniq
      rows = database.read { |db| db[:owned_processes].to_hash(:process_id) }
      assert_equal "running", rows.fetch(live).fetch(:state)
      assert_equal "stopped", rows.fetch(gone).fetch(:state)
      assert_equal "owner_gone_custody_unverified", rows.fetch(gone).fetch(:unknown_reason)
      reservation_states = database.read do |db|
        db[:launch_reservations].to_hash(:reservation_id, :state)
      end
      assert_equal "released", reservation_states.fetch(rows.fetch(gone).fetch(:reservation_id))
      assert_equal "registered", reservation_states.fetch(rows.fetch(live).fetch(:reservation_id))
      assert_empty registry.reconcile_exited_processes!
    end
  end

  def test_exited_direct_cli_rows_use_the_default_process_table_snapshot
    with_registry(use_default_process_table: true) do |database, registry, _root|
      process_id = register_process(registry, origin: "direct_cli", role: "status")
      gone_pid = spawn_gone_pid
      move_process(database, process_id, pid: gone_pid, session_id: gone_pid, process_group_id: gone_pid)

      assert_equal [ "root_gone_led_group_empty" ], registry.reconcile_exited_processes!.map { |row| row["evidence"] }
    end
  end

  def test_exited_cli_that_led_a_still_live_group_or_session_is_kept
    gone_pid = spawn_gone_pid
    {
      group: Hive::Attempts::ProcessTableSnapshot.new(session_ids: Set.new, process_group_ids: Set[gone_pid]),
      session: Hive::Attempts::ProcessTableSnapshot.new(session_ids: Set[gone_pid], process_group_ids: Set.new),
      unreadable: nil
    }.each do |name, table|
      with_registry(process_table: -> { table }) do |database, registry, _root|
        leader = register_process(registry, origin: "direct_cli", role: "babysit")
        move_process(database, leader, pid: gone_pid, session_id: gone_pid, process_group_id: gone_pid)

        assert_empty registry.reconcile_exited_processes!, name.to_s
        assert_equal "running", database.read { |db| db[:owned_processes].get(:state) }, name.to_s
      end
    end

    gone_pid = spawn_gone_pid
    with_registry(process_table: -> { EMPTY_TABLE }) do |database, registry, _root|
      leader = register_process(registry, origin: "direct_cli", role: "babysit")
      move_process(database, leader, pid: gone_pid, session_id: 9_999, process_group_id: gone_pid)
      assert_equal [ "root_gone_led_group_empty" ],
                   registry.reconcile_exited_processes!.map { |row| row["evidence"] }
    end
  end

  def test_exited_attempt_rows_need_a_settled_attempt_and_an_empty_session
    session_alive = Hive::Attempts::ProcessTableSnapshot.new(
      session_ids: Set[7_100], process_group_ids: Set.new
    )
    group_alive = Hive::Attempts::ProcessTableSnapshot.new(
      session_ids: Set.new, process_group_ids: Set[7_100]
    )
    [
      [ "running", EMPTY_TABLE, 7_100 ], [ "launching", EMPTY_TABLE, 7_100 ],
      [ nil, EMPTY_TABLE, 7_100 ], [ "terminal", session_alive, 7_100 ],
      [ "terminal", group_alive, 7_100 ], [ "lost", nil, 7_100 ], [ "terminal", EMPTY_TABLE, nil ]
    ].each do |attempt_state, table, session_id|
      with_registry(process_table: -> { table }) do |database, registry, _root|
        insert_attempt(database, "attempt-1", state: attempt_state) if attempt_state
        wrapper = register_process(registry, origin: "attempt", role: "attempt_wrapper", attempt_id: "attempt-1")
        move_process(database, wrapper, pid: spawn_gone_pid, session_id: session_id, process_group_id: 7_100)

        label = [ attempt_state, table&.session_ids&.to_a, session_id ].inspect
        assert_empty registry.reconcile_exited_processes!, label
        assert_equal "running", database.read { |db| db[:owned_processes].get(:state) }, label
      end
    end

    %w[terminal lost].each do |attempt_state|
      with_registry(process_table: -> { EMPTY_TABLE }) do |database, registry, _root|
        insert_attempt(database, "attempt-1", state: attempt_state)
        wrapper = register_process(registry, origin: "attempt", role: "attempt_wrapper", attempt_id: "attempt-1")
        move_process(database, wrapper, pid: spawn_gone_pid, session_id: 7_100, process_group_id: 7_100)

        assert_equal [ "attempt_settled_session_empty" ],
                     registry.reconcile_exited_processes!.map { |row| row["evidence"] }
        assert_equal "stopped", database.read { |db| db[:owned_processes].get(:state) }
      end
    end
  end

  def test_exited_process_reconciliation_leaves_delegated_and_unverifiable_rows_alone
    with_registry(process_table: -> { EMPTY_TABLE }) do |database, registry, _root|
      delegated = register_process(registry, origin: "direct_cli", role: "status")
      move_process(database, delegated, pid: spawn_gone_pid, session_id: 7_200, process_group_id: 7_200)
      database.transaction do |db|
        db[:owned_processes].update(custody_mode: "delegated_cgroup_v2", custody_path: "/hive/x")
      end
      assert_empty registry.reconcile_exited_processes!
    end

    identity = UnverifiableOwnerIdentity.new(Hive::Attempts::ProcessIdentity.new)
    with_registry(process_identity: identity, process_table: -> { EMPTY_TABLE }) do |database, registry, _root|
      register_process(registry, origin: "direct_cli", role: "status")
      database.transaction { |db| db[:owned_processes].update(start_fingerprint: "not-this-process") }
      assert_empty registry.reconcile_exited_processes!
    end
  end

  def test_exited_process_reconciliation_keeps_rows_when_the_process_table_raises
    with_registry(process_table: -> { raise ArgumentError, "unavailable" }) do |database, registry, _root|
      process_id = register_process(registry, origin: "direct_cli", role: "status")
      gone_pid = spawn_gone_pid
      move_process(database, process_id, pid: gone_pid, session_id: gone_pid, process_group_id: gone_pid)

      assert_empty registry.reconcile_exited_processes!
      assert_equal "running", database.read { |db| db[:owned_processes].get(:state) }
    end
  end

  def test_exited_process_reconciliation_is_bounded_per_call
    with_registry(process_table: -> { EMPTY_TABLE }) do |database, registry, _root|
      gone_pid = spawn_gone_pid
      3.times do
        id = register_process(registry, origin: "direct_cli", role: "digest")
        move_process(database, id, pid: gone_pid, session_id: 7_300, process_group_id: 7_300)
      end

      assert_equal 2, registry.reconcile_exited_processes!(limit: 2).size
      assert_equal 1, registry.reconcile_exited_processes!(limit: 2).size
      assert_empty registry.reconcile_exited_processes!(limit: 2)
    end
  end

  def test_capability_becomes_eligible_once_exited_attempt_rows_are_reconciled
    with_registry(process_table: -> { EMPTY_TABLE }) do |database, registry, root|
      capability = Hive::RuntimeControlPlane::QuiescenceCapability.new(
        database: database, state_home: root,
        legacy_inventory: -> { [] }, custody: Hive::Attempts::ProcessCustody.unsupported("test")
      )
      insert_attempt(database, "attempt-1", state: "lost")
      wrapper = register_process(registry, origin: "attempt", role: "attempt_wrapper", attempt_id: "attempt-1")
      move_process(database, wrapper, pid: spawn_gone_pid, session_id: 7_400, process_group_id: 7_400)
      cli = register_process(registry, origin: "direct_cli", role: "brainstorm")
      move_process(database, cli, pid: spawn_gone_pid, session_id: 7_400, process_group_id: 7_401)
      assert_equal "agent_attempt_root", capability.call.reason

      assert_equal 2, registry.reconcile_exited_processes!.size
      assert capability.call.eligible?
    end
  end

  private

  def spawn_gone_pid
    pid = Process.spawn("true")
    Process.wait(pid)
    pid
  end

  def register_process(registry, origin:, role:, attempt_id: nil)
    reservation = registry.reserve!(origin: origin, role: role, attempt_id: attempt_id)
    registry.register!(reservation.id, pid: Process.pid).process_id
  ensure
    reservation&.release_fence!
  end

  def move_process(database, process_id, pid:, session_id:, process_group_id:)
    database.transaction do |db|
      db[:owned_processes].where(process_id: process_id).update(
        pid: pid, session_id: session_id, process_group_id: process_group_id
      )
    end
  end

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
        outcome: state == "terminal" ? "failed" : nil,
        lease_version: 0, retry_charge: 0, refunded: 0, source_fingerprint: "source",
        details_json: "{}", project_name: "demo", task_slug: task_id,
        accepted_date: "2026-11-04", created_at: now, accepted_at: now
      )
    end
  end

  def with_registry(process_identity: Hive::Attempts::ProcessIdentity.new,
                    process_table: -> { Hive::Attempts::ProcessTable.snapshot }, use_default_process_table: false)
    with_tmp_dir do |root|
      database = Hive::RuntimeControlPlane::Database.new(
        path: Hive::Paths.runtime_control_plane_path(root)
      ).migrate!
      options = { database: database, state_home: root, process_identity: process_identity }
      options[:process_table] = process_table unless use_default_process_table
      registry = Hive::RuntimeControlPlane::ProcessRegistry.new(**options)
      yield database, registry, root
    ensure
      database&.disconnect
    end
  end
end
