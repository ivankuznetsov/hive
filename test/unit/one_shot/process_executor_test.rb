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

    assert_equal 7260.0, executor.instance_variable_get(:@timeout_sec)
    assert_equal 12.0, executor.instance_variable_get(:@kill_grace_sec)
  end

  def test_project_factory_ignores_invalid_worker_timeouts
    executor = Hive::OneShot::ProcessExecutor.for_entry(
      { "path" => "/tmp/project" },
      config_loader: ->(*) {
        {
          "timeout_sec" => { "patrol" => "invalid" },
          "refactor_patrol" => { "max_review_seconds_per_run" => -1 }
        }
      },
      daemon_config_loader: -> { {} }
    )

    assert_equal Hive::OneShot::ProcessExecutor::DEFAULT_TIMEOUT_SEC,
                 executor.instance_variable_get(:@timeout_sec)
    assert_equal Hive::OneShot::ProcessExecutor::DEFAULT_KILL_GRACE_SEC,
                 executor.instance_variable_get(:@kill_grace_sec)
  end

  def test_invalid_timeout_arguments_are_rejected
    assert_raises(ArgumentError) do
      Hive::OneShot::ProcessExecutor.new(timeout_sec: "invalid")
    end
    assert_raises(ArgumentError) do
      Hive::OneShot::ProcessExecutor.new(kill_grace_sec: -1)
    end
  end

  def test_terminate_delegates_process_group_lifecycle_to_child_supervisor
    executor = Hive::OneShot::ProcessExecutor.new(
      monotonic_clock: -> { 0.0 }, sleeper: ->(*) { }
    )
    arguments = nil
    replacement = lambda do |**keywords|
      arguments = keywords
      :killed
    end

    with_replaced_singleton_method(
      Hive::Daemon::ChildSupervisor, :terminate_pid, replacement
    ) do
      assert_equal :killed, executor.send(:terminate, 123)
    end
    assert_equal 123, arguments.fetch(:pid)
    assert_equal 123, arguments.fetch(:pgid)
  end

  def test_reader_timeout_terminates_before_raising
    reader = Object.new
    reader.define_singleton_method(:join) { |_timeout| false }
    executor = Hive::OneShot::ProcessExecutor.new(monotonic_clock: -> { 0.0 })
    terminated = []
    executor.define_singleton_method(:terminate) { |pid| terminated << pid }

    error = assert_raises(Hive::InternalError) do
      executor.send(:reader_value, reader, 1.0, 123)
    end
    assert_match(/draining output/, error.message)
    assert_equal [ 123 ], terminated
  end

  def test_output_drain_gets_a_fresh_deadline_after_child_exit
    times = [ 100.0, 100.0 ]
    executor = Hive::OneShot::ProcessExecutor.new(
      timeout_sec: 100, monotonic_clock: -> { times.shift || 100.0 }
    )
    status = Struct.new(:exitstatus).new(0)
    reader = Object.new
    joins = []
    reader.define_singleton_method(:join) { |timeout| joins << timeout; true }
    reader.define_singleton_method(:value) { "" }
    executor.define_singleton_method(:wait_for_exit) { |_pid, _deadline| status }

    executor.send(:reader_value, reader, executor.send(:output_drain_deadline), 123)

    assert_equal [ Hive::OneShot::ProcessExecutor::OUTPUT_DRAIN_TIMEOUT_SEC ], joins
  end

  def test_terminate_tolerates_an_already_gone_process
    executor = Hive::OneShot::ProcessExecutor.new

    assert_nil executor.send(:terminate, 2_147_483_647)
  end
end
