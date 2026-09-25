require "test_helper"
require "hive/one_shot/process_executor"

class OneShotProcessExecutorTest < Minitest::Test
  include HiveTestHelper

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

  def test_hive_command_uses_the_pinned_runtime_binary
    with_tmp_dir do |dir|
      hive = File.join(dir, "hive")
      File.write(hive, "#!/bin/sh\nprintf '%s\\n' '{\"pinned\":true}'\n")
      FileUtils.chmod(0o755, hive)

      with_env("HIVE_BIN" => hive) do
        execution = Hive::OneShot::ProcessExecutor.new.call("hive patrol demo --json")
        assert_equal({ "pinned" => true }, execution.envelope)
      end
    end
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

  def test_timeout_escalates_past_term_resistance_without_hanging
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Hive::InternalError) do
      Hive::OneShot::ProcessExecutor.new(
        timeout_sec: 0.05, kill_grace_sec: 0.05
      ).call("ruby -e 'trap(\"TERM\") {}; sleep 30'")
    end

    assert_match(/timed out/, error.message)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
  end

  def test_project_factory_uses_existing_worker_timeout_and_kill_grace
    executor = Hive::OneShot::ProcessExecutor.for_entry(
      { "path" => "/tmp/project" },
      config_loader: ->(*) {
        {
          "timeout_sec" => { "patrol" => 7200 },
          "refactor_patrol" => { "max_review_seconds_per_run" => 3600 }
        }
      },
      daemon_config_loader: -> { { "child_kill_grace_sec" => 12 } }
    )

    assert_equal 7200.0, executor.instance_variable_get(:@timeout_sec)
    assert_equal 12.0, executor.instance_variable_get(:@kill_grace_sec)
  end

  def test_terminate_tolerates_an_already_gone_process
    executor = Hive::OneShot::ProcessExecutor.new

    assert_nil executor.send(:terminate, 2_147_483_647)
  end
end
