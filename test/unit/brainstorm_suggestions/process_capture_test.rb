require "test_helper"
require "hive/brainstorm_suggestions/process_capture"

class HiveBrainstormSuggestionsProcessCaptureTest < Minitest::Test
  def test_capture_bounds_a_descendant_held_output_pipe_after_leader_exit
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_raises(Hive::BrainstormSuggestions::ProcessCapture::Timeout) do
      Hive::BrainstormSuggestions::ProcessCapture.call(
        [ "/bin/sh", "-c", "(trap '' TERM; sleep 10) & exit 0" ],
        deadline: started + 0.05,
        max_bytes: 1_024,
        poll_interval: 0.005
      )
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 1.0
  end

  def test_capture_stops_oversized_output_without_waiting_for_process_exit
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_raises(Hive::BrainstormSuggestions::ProcessCapture::TooLarge) do
      Hive::BrainstormSuggestions::ProcessCapture.call(
        [ "/bin/sh", "-c", "yes x" ],
        deadline: started + 5,
        max_bytes: 128,
        poll_interval: 0.005
      )
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 1.0
  end

  def test_capture_returns_bounded_output_and_status
    result = Hive::BrainstormSuggestions::ProcessCapture.call(
      [ "/bin/sh", "-c", "printf success" ],
      deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1,
      max_bytes: 128
    )

    assert_equal "success", result.output
    assert result.status.success?
  end

  def test_terminate_escalates_a_term_ignoring_process_group
    pid = Process.spawn(
      "/bin/sh", "-c", "trap '' TERM; while :; do sleep 1; done", pgroup: true
    )

    result = Timeout.timeout(2) do
      Hive::BrainstormSuggestions::ProcessCapture.terminate(pid)
    end
    assert_equal pid, result
  ensure
    begin
      Process.kill("KILL", -pid) if pid
      Process.waitpid(pid) if pid
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end

  def test_terminate_accepts_missing_processes
    assert_nil Hive::BrainstormSuggestions::ProcessCapture.terminate(nil)
    assert_nil Hive::BrainstormSuggestions::ProcessCapture.terminate(999_999_999)
  end

  def test_terminate_kills_a_group_after_its_leader_was_reaped
    pid = Process.spawn("/bin/sh", "-c", "sleep 10 &", pgroup: true)
    Process.waitpid(pid)

    assert_equal pid, Hive::BrainstormSuggestions::ProcessCapture.terminate(pid)
    assert_raises(Errno::ESRCH) { Process.kill(0, -pid) }
  ensure
    begin
      Process.kill("KILL", -pid) if pid
    rescue Errno::ESRCH
      nil
    end
  end
end
