require "test_helper"
require "hive/process_kill"
require "hive/lock"

# Direct unit tests for the security-sensitive PID kill/reuse logic
# in Hive::ProcessKill. Drop covers the happy path incidentally;
# these pin the guard arms (invalid_pid, not_alive, pid_reuse_guard,
# permission_denied, kill_failed) so a regression in any of them
# fails here instead of letting drop signal a foreign PID silently.
class ProcessKillTest < Minitest::Test
  include HiveTestHelper
  def test_terminate_process_refuses_pid_zero_as_invalid
    result = Hive::ProcessKill.terminate_process(0)
    assert_equal 0, result.pid
    refute result.killed
    assert_equal "invalid_pid", result.skipped_reason,
                 "PID 0 means current process group to Process.kill; must be rejected before signalling"
  end

  def test_terminate_process_refuses_pid_one_as_invalid
    result = Hive::ProcessKill.terminate_process(1)
    refute result.killed
    assert_equal "invalid_pid", result.skipped_reason,
                 "PID 1 is init; must be rejected outright"
  end

  def test_terminate_process_group_refuses_pid_zero_as_invalid
    result = Hive::ProcessKill.terminate_process_group(0)
    refute result.killed
    assert_equal "invalid_pid", result.skipped_reason,
                 "PID 0 → negation would target current process group; reject before signalling"
  end

  def test_terminate_process_returns_invalid_pid_for_nil_argument
    result = Hive::ProcessKill.terminate_process(nil)
    assert_nil result.pid
    refute result.killed
    assert_equal "invalid_pid", result.skipped_reason
  end

  def test_terminate_process_returns_not_alive_for_dead_pid
    # PID space is finite but a very large number is almost certainly
    # not currently allocated to a live process.
    dead_pid = 999_999
    result = Hive::ProcessKill.terminate_process(dead_pid)
    refute result.killed
    assert_equal "not_alive", result.skipped_reason
  end

  def test_terminate_process_pid_reuse_guard_when_start_time_does_not_match
    # Use the current PID so it's definitely alive, but record a fake
    # start-time so the guard rejects rather than signalling.
    result = Hive::ProcessKill.terminate_process(
      Process.pid, recorded_start_time: "definitely-not-this-process"
    )
    refute result.killed, "must not signal ourselves when start-time guard fails"
    assert_equal "pid_reuse_guard", result.skipped_reason
  end

  def test_pid_owned_by_recorded_start_returns_true_when_recorded_start_time_blank
    # Empty recorded → trust the recorded pid (only path that lets a
    # legitimate kill proceed when start-time isn't pinned).
    assert Hive::ProcessKill.pid_owned_by_recorded_start?(Process.pid, "")
    assert Hive::ProcessKill.pid_owned_by_recorded_start?(Process.pid, nil)
  end

  def test_pid_owned_by_recorded_start_returns_true_when_live_lookup_yields_blank
    # When the live start-time lookup fails (containerised /proc, etc.)
    # the guard falls through to trust-the-recorded-pid so legitimate
    # cleanup still works. Stub the lookup to return nil.
    with_process_start_time_stub(nil) do
      assert Hive::ProcessKill.pid_owned_by_recorded_start?(
        Process.pid, "some-recorded-start-time"
      )
    end
  end

  def test_pid_owned_by_recorded_start_returns_false_when_start_times_diverge
    with_process_start_time_stub("live-start-time") do
      refute Hive::ProcessKill.pid_owned_by_recorded_start?(
        Process.pid, "different-recorded-time"
      )
    end
  end

  def test_valid_target_pid_predicate_rejects_zero_one_and_non_integers
    refute Hive::ProcessKill.valid_target_pid?(0)
    refute Hive::ProcessKill.valid_target_pid?(1)
    refute Hive::ProcessKill.valid_target_pid?(-1)
    refute Hive::ProcessKill.valid_target_pid?(nil)
    refute Hive::ProcessKill.valid_target_pid?("123")
    assert Hive::ProcessKill.valid_target_pid?(2)
    assert Hive::ProcessKill.valid_target_pid?(999_999)
  end

  # Spawn a real child, let it terminate, then verify terminate_process
  # reports killed=true with no skipped_reason.
  def test_terminate_process_kills_a_real_short_lived_child
    pid = Process.spawn("sleep", "30", out: File::NULL, err: File::NULL)
    begin
      result = Hive::ProcessKill.terminate_process(pid, grace_seconds: 1.0)
      assert_equal pid, result.pid
      assert result.killed, "real child must be killed by SIGTERM/SIGKILL escalation"
      assert_nil result.skipped_reason
    ensure
      begin
        Process.waitpid(pid, Process::WNOHANG)
      rescue Errno::ECHILD
        # already reaped
      end
    end
  end

  def test_pid_alive_treats_permission_denied_as_alive
    with_replaced_singleton_method(Process, :kill, lambda { |_signal, _pid| raise Errno::EPERM }) do
      assert Hive::ProcessKill.pid_alive?(1234)
    end
  end

  def test_process_start_time_returns_nil_for_malformed_pid
    assert_nil Hive::ProcessKill.process_start_time("not-a-pid")
  end

  def test_terminate_process_escalates_to_kill_when_term_does_not_stop_process
    alive_sequence = [ true, true, false ]
    signals = []
    with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, lambda { |_pid| alive_sequence.shift }) do
      with_replaced_singleton_method(Hive::ProcessKill, :safe_kill, lambda { |signal, pid| signals << [ signal, pid ] }) do
        with_replaced_singleton_method(Hive::ProcessKill, :wait_until_dead, lambda { |_pid, _seconds| false }) do
          result = Hive::ProcessKill.terminate_process(1234, grace_seconds: 0)

          assert_equal [ [ "TERM", 1234 ], [ "KILL", 1234 ] ], signals
          assert result.killed
          assert_nil result.skipped_reason
        end
      end
    end
  end

  def test_terminate_process_reports_permission_denied_when_signal_fails
    with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, lambda { |_pid| true }) do
      with_replaced_singleton_method(Hive::ProcessKill, :safe_kill, lambda { |_signal, _pid| raise Errno::EPERM }) do
        result = Hive::ProcessKill.terminate_process(1234, grace_seconds: 0)

        refute result.killed
        assert_equal "permission_denied", result.skipped_reason
      end
    end
  end

  def test_terminate_process_group_pid_reuse_guard_when_start_time_does_not_match
    with_process_start_time_stub("live-start-time") do
      result = Hive::ProcessKill.terminate_process_group(
        Process.pid, recorded_start_time: "different-recorded-time"
      )

      refute result.killed
      assert_equal "pid_reuse_guard", result.skipped_reason
    end
  end

  def test_terminate_process_group_returns_invalid_pid_for_nil_argument
    result = Hive::ProcessKill.terminate_process_group(nil)

    assert_nil result.pid
    refute result.killed
    assert_equal "invalid_pid", result.skipped_reason
  end

  def test_terminate_process_group_escalates_to_kill_when_term_does_not_stop_process
    alive_sequence = [ true, true, false ]
    signals = []
    with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, lambda { |_pid| alive_sequence.shift }) do
      with_replaced_singleton_method(Process, :getpgid, lambda { |pid| pid }) do
        with_replaced_singleton_method(Hive::ProcessKill, :safe_kill, lambda { |signal, target| signals << [ signal, target ] }) do
          with_replaced_singleton_method(Hive::ProcessKill, :wait_until_dead, lambda { |_pid, _seconds| false }) do
            result = Hive::ProcessKill.terminate_process_group(1234, grace_seconds: 0)

            assert_equal [ [ "TERM", -1234 ], [ "KILL", -1234 ] ], signals
            assert result.killed
            assert_nil result.skipped_reason
          end
        end
      end
    end
  end

  def test_terminate_process_group_reports_not_alive_when_group_disappears
    with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, lambda { |_pid| true }) do
      with_replaced_singleton_method(Process, :getpgid, lambda { |_pid| raise Errno::ESRCH }) do
        result = Hive::ProcessKill.terminate_process_group(1234, grace_seconds: 0)

        refute result.killed
        assert_equal "not_alive", result.skipped_reason
      end
    end
  end

  def test_terminate_process_group_reports_permission_denied_when_signal_fails
    with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, lambda { |_pid| true }) do
      with_replaced_singleton_method(Process, :getpgid, lambda { |pid| pid }) do
        with_replaced_singleton_method(Hive::ProcessKill, :safe_kill, lambda { |_signal, _target| raise Errno::EPERM }) do
          result = Hive::ProcessKill.terminate_process_group(1234, grace_seconds: 0)

          refute result.killed
          assert_equal "permission_denied", result.skipped_reason
        end
      end
    end
  end

  def test_safe_kill_ignores_missing_targets
    with_replaced_singleton_method(Process, :kill, lambda { |_signal, _target| raise Errno::ESRCH }) do
      assert_nil Hive::ProcessKill.safe_kill("TERM", 1234)
    end
  end

  def test_safe_kill_propagates_permission_denied
    with_replaced_singleton_method(Process, :kill, lambda { |_signal, _target| raise Errno::EPERM }) do
      assert_raises(Errno::EPERM) { Hive::ProcessKill.safe_kill("TERM", 1234) }
    end
  end

  def test_wait_until_dead_checks_final_state_after_deadline
    with_replaced_singleton_method(Hive::ProcessKill, :reap_if_child_exited, lambda { |_pid| false }) do
      with_replaced_singleton_method(Hive::ProcessKill, :pid_alive?, lambda { |_pid| false }) do
        assert Hive::ProcessKill.wait_until_dead(1234, 0)
      end
    end
  end

  def test_reap_if_child_exited_returns_false_for_non_child
    refute Hive::ProcessKill.reap_if_child_exited(999_999)
  end


  private

  # Temporarily replace ProcessKill.process_start_time so we can pin
  # the pid-reuse-guard branches deterministically. Restores the
  # original singleton method on exit.
  def with_process_start_time_stub(value)
    mod = Hive::ProcessKill.singleton_class
    original = mod.instance_method(:process_start_time)
    mod.send(:define_method, :process_start_time) { |_pid| value }
    yield
  ensure
    mod.send(:define_method, :process_start_time, original) if original
  end
end
