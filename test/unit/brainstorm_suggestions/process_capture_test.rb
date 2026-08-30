require "test_helper"
require "hive/brainstorm_suggestions/process_capture"

class HiveBrainstormSuggestionsProcessCaptureTest < Minitest::Test
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
end
