require "test_helper"
require "hive/attempts/process_identity"

class AttemptsProcessIdentityTest < Minitest::Test
  def identity(start: "start-1", session: 10, group: 10)
    {
      "pid" => 123,
      "start_fingerprint" => start,
      "session_id" => session,
      "process_group_id" => group
    }
  end

  def checker(alive: true, start: "start-1", session: 10, group: 10)
    signaler = lambda do |_signal, _pid|
      raise Errno::ESRCH unless alive
    end
    Hive::Attempts::ProcessIdentity.new(
      start_reader: ->(_pid) { start }, signaler: signaler,
      session_reader: ->(_pid) { session }, group_reader: ->(_pid) { group }
    )
  end

  def test_matching_identity_requires_pid_start_session_and_group
    assert_equal :matching, checker.status(identity)
    assert_equal :mismatched, checker(start: "reused").status(identity)
    assert_equal :mismatched, checker(group: 11).status(identity)
  end

  def test_missing_and_unverifiable_are_distinct
    assert_equal :missing, checker(alive: false).status(identity)
    assert_equal :unverifiable, checker(start: nil).status(identity)
    assert_equal :unverifiable, checker.status(identity(start: ""))
  end

  def test_group_safety_rejects_non_session_leader_and_foreign_worker
    verifier = checker
    assert verifier.safe_group?(wrapper: identity)
    refute verifier.safe_group?(wrapper: identity(group: 11))
    refute verifier.safe_group?(
      wrapper: identity,
      worker: identity.merge("pid" => 456, "session_id" => 99)
    )
  end

  def test_orphan_cleanup_rechecks_identity_and_signals_only_verified_group
    alive = true
    signals = []
    signaler = lambda do |signal, pid|
      raise Errno::ESRCH if signal == 0 && !alive

      signals << [ signal, pid ] unless signal == 0
      alive = false if signal == "TERM"
    end
    verifier = Hive::Attempts::ProcessIdentity.new(
      start_reader: ->(_pid) { "worker-start" }, signaler: signaler,
      session_reader: ->(_pid) { 10 }, group_reader: ->(_pid) { 456 },
      sleeper: ->(_seconds) { }, monotonic: -> { 0.0 }
    )
    wrapper = identity(start: "wrapper-start", session: 10, group: 10)
    worker = identity(start: "worker-start", session: 10, group: 456).merge("pid" => 456)

    assert_equal :terminated,
                 verifier.terminate_orphan_group(wrapper: wrapper, worker: worker, grace_sec: 0)
    assert_equal [ [ "TERM", -456 ] ], signals
  end

  def test_orphan_cleanup_never_signals_mismatched_session
    signals = []
    signaler = lambda do |signal, pid|
      signals << [ signal, pid ] unless signal == 0
    end
    verifier = Hive::Attempts::ProcessIdentity.new(
      start_reader: ->(_pid) { "worker-start" }, signaler: signaler,
      session_reader: ->(_pid) { 99 }, group_reader: ->(_pid) { 456 }
    )
    wrapper = identity(start: "wrapper-start", session: 10, group: 10)
    worker = identity(start: "worker-start", session: 10, group: 456).merge("pid" => 456)

    assert_equal :identity_mismatch,
                 verifier.terminate_orphan_group(wrapper: wrapper, worker: worker)
    assert_empty signals
  end

  def test_missing_worker_leader_does_not_hide_a_live_process_group
    probes = []
    signaler = lambda do |signal, pid|
      probes << [ signal, pid ]
      raise Errno::ESRCH if signal == 0 && pid == 456
    end
    verifier = Hive::Attempts::ProcessIdentity.new(
      start_reader: ->(_pid) { "worker-start" }, signaler: signaler,
      session_reader: ->(_pid) { 10 }, group_reader: ->(_pid) { 456 }
    )
    wrapper = identity(start: "wrapper-start", session: 10, group: 10)
    worker = identity(start: "worker-start", session: 10, group: 456).merge("pid" => 456)

    assert_equal :unverifiable, verifier.orphan_group_status(wrapper: wrapper, worker: worker)
    assert_equal :identity_mismatch,
                 verifier.terminate_orphan_group(wrapper: wrapper, worker: worker)
    assert_includes probes, [ 0, -456 ]
    refute probes.any? { |signal, _pid| %w[TERM KILL].include?(signal) }
  end

  def test_missing_worker_leader_is_absent_only_when_its_group_is_gone
    signaler = lambda do |signal, pid|
      raise Errno::ESRCH if signal == 0 && [ 456, -456 ].include?(pid)
    end
    verifier = Hive::Attempts::ProcessIdentity.new(
      start_reader: ->(_pid) { "worker-start" }, signaler: signaler,
      session_reader: ->(_pid) { 10 }, group_reader: ->(_pid) { 456 }
    )
    wrapper = identity(start: "wrapper-start", session: 10, group: 10)
    worker = identity(start: "worker-start", session: 10, group: 456).merge("pid" => 456)

    assert_equal :absent, verifier.orphan_group_status(wrapper: wrapper, worker: worker)
    assert_equal :absent, verifier.terminate_orphan_group(wrapper: wrapper, worker: worker)
  end

  def test_capture_and_snapshot_hash_cover_live_missing_and_invalid_pids
    snapshot = Hive::Attempts::ProcessIdentity.new.capture(Process.pid)
    assert_equal Process.pid, snapshot.pid
    assert_equal Process.pid, snapshot.to_h.fetch("pid")

    refute checker(alive: false).capture(123)
    refute Hive::Attempts::ProcessIdentity.new(
      start_reader: ->(_pid) { nil }, signaler: ->(_signal, _pid) { },
      session_reader: ->(_pid) { 1 }, group_reader: ->(_pid) { 1 }
    ).capture(123)
    assert_nil checker.capture("not-a-pid")
  end

  def test_status_maps_reader_errors_and_safe_worker_matches
    expected = identity
    assert_equal :unverifiable, checker.status("bad")
    assert checker.safe_group?(wrapper: expected, worker: expected.merge("pid" => 456))

    esrch = Hive::Attempts::ProcessIdentity.new(
      start_reader: ->(_pid) { raise Errno::ESRCH }, signaler: ->(_signal, _pid) { },
      session_reader: ->(_pid) { 10 }, group_reader: ->(_pid) { 10 }
    )
    assert_equal :missing, esrch.status(expected)

    eperm = Hive::Attempts::ProcessIdentity.new(
      start_reader: ->(_pid) { raise Errno::EPERM },
      signaler: ->(_signal, _pid) { raise Errno::EPERM },
      session_reader: ->(_pid) { 10 }, group_reader: ->(_pid) { 10 }
    )
    assert_equal :unverifiable, eperm.status(expected)
    assert_nil eperm.capture(123)
  end

  def test_orphan_cleanup_uses_kill_and_reports_changed_or_persistent_identity
    signals = []
    killed = false
    monotonic = 0
    verifier = Hive::Attempts::ProcessIdentity.new(
      start_reader: ->(_pid) { "worker-start" },
      signaler: lambda { |signal, _pid|
        raise Errno::ESRCH if signal == 0 && killed
        signals << signal unless signal == 0
        killed = true if signal == "KILL"
      },
      session_reader: ->(_pid) { 10 }, group_reader: ->(_pid) { 456 },
      sleeper: ->(_seconds) { }, monotonic: -> { monotonic += 1 }
    )
    wrapper = identity(start: "wrapper-start", session: 10, group: 10)
    worker = identity(start: "worker-start", session: 10, group: 456).merge("pid" => 456)
    assert_equal :terminated,
                 verifier.terminate_orphan_group(wrapper: wrapper, worker: worker, grace_sec: 0)
    assert_equal %w[TERM KILL], signals

    persistent = Hive::Attempts::ProcessIdentity.new(
      start_reader: ->(_pid) { "worker-start" }, signaler: ->(_signal, _pid) { },
      session_reader: ->(_pid) { 10 }, group_reader: ->(_pid) { 456 },
      sleeper: ->(_seconds) { }, monotonic: -> { 1 }
    )
    assert_equal :still_alive,
                 persistent.terminate_orphan_group(wrapper: wrapper, worker: worker, grace_sec: 0)
  end

  def test_default_timing_hooks_and_status_argument_error_paths
    verifier = Hive::Attempts::ProcessIdentity.new
    verifier.instance_variable_get(:@sleeper).call(0)
    assert_kind_of Numeric, verifier.instance_variable_get(:@monotonic).call
    assert_equal :unverifiable, checker.status("pid" => "not-a-pid")
  end

  def test_orphan_cleanup_waits_then_handles_signal_errors
    ticks = [ 0.0, 0.0, 0.1, 1.0 ]
    sleeps = []
    waiting = Hive::Attempts::ProcessIdentity.new(
      start_reader: ->(_pid) { "worker-start" }, signaler: ->(_signal, _pid) { },
      session_reader: ->(_pid) { 10 }, group_reader: ->(_pid) { 456 },
      sleeper: ->(seconds) { sleeps << seconds }, monotonic: -> { ticks.shift || 1.0 }
    )
    wrapper = identity(start: "wrapper-start", session: 10, group: 10)
    worker = identity(start: "worker-start", session: 10, group: 456).merge("pid" => 456)
    assert_equal :still_alive,
                 waiting.terminate_orphan_group(wrapper: wrapper, worker: worker, grace_sec: 0.5)
    refute_empty sleeps

    missing = Hive::Attempts::ProcessIdentity.new(
      start_reader: ->(_pid) { "worker-start" },
      signaler: ->(signal, _pid) { raise Errno::ESRCH if signal == "TERM" },
      session_reader: ->(_pid) { 10 }, group_reader: ->(_pid) { 456 }
    )
    assert_equal :terminated, missing.terminate_orphan_group(wrapper: wrapper, worker: worker)

    denied = Hive::Attempts::ProcessIdentity.new(
      start_reader: ->(_pid) { "worker-start" },
      signaler: ->(signal, _pid) { raise Errno::EPERM if signal == "TERM" },
      session_reader: ->(_pid) { 10 }, group_reader: ->(_pid) { 456 }
    )
    assert_equal :identity_mismatch, denied.terminate_orphan_group(wrapper: wrapper, worker: worker)
  end

  def test_process_group_presence_handles_permission_and_probe_errors
    denied = Hive::Attempts::ProcessIdentity.new(
      signaler: ->(_signal, _pid) { raise Errno::EPERM }
    )
    assert_equal :alive, denied.send(:process_group_presence, 456)

    invalid = Hive::Attempts::ProcessIdentity.new(
      signaler: ->(_signal, _pid) { raise Errno::EINVAL }
    )
    assert_equal :unverifiable, invalid.send(:process_group_presence, 456)
  end
end
