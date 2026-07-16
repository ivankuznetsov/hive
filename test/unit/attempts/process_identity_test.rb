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
end
