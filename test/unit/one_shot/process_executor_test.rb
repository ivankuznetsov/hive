require "test_helper"
require "hive/one_shot/process_executor"

class OneShotProcessExecutorTest < Minitest::Test
  def test_executes_a_child_and_returns_its_json_envelope
    command = "ruby -rjson -e 'STDERR.write(\"warning\\n\"); puts JSON.generate(ok: true)'"

    _out, err = capture_io do
      execution = Hive::OneShot::ProcessExecutor.new.call(command)

      assert_equal 0, execution.exit_code
      assert_equal({ "ok" => true }, execution.envelope)
    end
    assert_equal "warning\n", err
  end

  def test_empty_output_and_invalid_json_are_distinguished
    execution = Hive::OneShot::ProcessExecutor.new.call("ruby -e 'exit 3'")
    assert_equal 3, execution.exit_code
    assert_nil execution.envelope

    error = assert_raises(Hive::InternalError) do
      Hive::OneShot::ProcessExecutor.new.call("ruby -e 'puts \"not-json\"'")
    end
    assert_match(/invalid JSON/, error.message)
  end

  def test_exception_terminates_an_unsettled_process_group
    spawned = Queue.new
    thread = Thread.new do
      Hive::OneShot::ProcessExecutor.new.call(
        "ruby -e 'sleep 30'", on_spawn: ->(pid) { spawned << pid }
      )
    end
    thread.report_on_exception = false
    spawned.pop
    thread.raise RuntimeError, "stop"

    error = assert_raises(RuntimeError) { thread.value }
    assert_equal "stop", error.message
  ensure
    thread&.kill
    begin
      thread&.join
    rescue RuntimeError
      nil
    end
  end

  def test_terminate_tolerates_an_already_gone_process
    executor = Hive::OneShot::ProcessExecutor.new

    assert_nil executor.send(:terminate, 2_147_483_647)
  end
end
