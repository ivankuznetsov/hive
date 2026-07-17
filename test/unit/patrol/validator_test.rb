require "test_helper"
require "hive/patrol/validator"

class HivePatrolValidatorTest < Minitest::Test
  include HiveTestHelper

  def test_no_commands_is_not_validatable
    validator = Hive::Patrol::Validator.new({})
    result = validator.validate(Dir.pwd)

    assert_equal false, validator.configured?
    assert_equal false, result["passed"]
    assert_equal "no_validation_commands", result["reason"]
  end

  def test_configured_ignores_blank_and_unsupported_commands
    validator = Hive::Patrol::Validator.new(
      "format" => "  ",
      "lint" => nil,
      "deploy" => "true"
    )

    assert_equal false, validator.configured?
  end

  def test_all_commands_must_pass
    with_tmp_dir do |dir|
      validator = Hive::Patrol::Validator.new(
        "lint" => "test -d .",
        "test" => "exit 9"
      )

      result = validator.validate(dir)

      assert_equal false, result["passed"]
      assert_equal [ 0, 9 ], result["commands"].map { |cmd| cmd["exit_code"] }
    end
  end

  def test_passing_commands_pass
    with_tmp_dir do |dir|
      validator = Hive::Patrol::Validator.new("test" => "pwd >/dev/null")
      result = validator.validate(dir)

      assert_equal true, validator.configured?
      assert_equal true, result["passed"]
    end
  end

  def test_selected_names_run_only_requested_configured_commands
    with_tmp_dir do |dir|
      validator = Hive::Patrol::Validator.new(
        "docs" => "printf docs",
        "test" => "exit 9"
      )

      result = validator.validate(dir, names: [ "docs" ])

      assert_equal true, result["passed"]
      assert_equal [ "docs" ], result["commands"].map { |command| command["name"] }
    end
  end

  def test_command_timeout_is_bounded_and_reported
    with_tmp_dir do |dir|
      validator = Hive::Patrol::Validator.new(
        { "test" => "ruby -e 'sleep 5'" },
        timeout_sec: 0.1
      )

      result = validator.validate(dir)

      assert_equal false, result["passed"]
      assert_equal 124, result["commands"].first["exit_code"]
      assert_equal true, result["commands"].first["timed_out"]
    end
  end

  def test_command_output_is_capped_while_the_process_is_drained
    with_tmp_dir do |dir|
      validator = Hive::Patrol::Validator.new(
        { "test" => "ruby -e '$stdout.write(%q[x] * 10_000); $stderr.write(%q[y] * 10_000)'" },
        max_output_bytes: 128
      )

      command = validator.validate(dir)["commands"].first

      assert_operator command["stdout"].bytesize, :<=, 128
      assert_operator command["stderr"].bytesize, :<=, 128
      assert_equal true, command["output_truncated"]
    end
  end

  def test_signaled_validation_is_never_treated_as_success
    with_tmp_dir do |dir|
      validator = Hive::Patrol::Validator.new(
        "test" => "ruby -e 'Process.kill(%q[KILL], Process.pid)'"
      )

      result = validator.validate(dir)
      command = result["commands"].first

      assert_equal false, result["passed"]
      refute_equal 0, command["exit_code"]
      assert_equal false, Hive::Patrol::Validator::CommandResult.new(
        name: "test", command: "killed", exit_code: nil, signal: 9,
        stdout: "", stderr: "", timed_out: false, output_truncated: false
      ).passed?
    end
  end

  def test_command_system_error_is_reported_as_127
    with_tmp_dir do |dir|
      with_replaced_singleton_method(Open3, :popen3, ->(*) { raise Errno::ENOENT, "bash" }) do
        result = Hive::Patrol::Validator.new("test" => "anything").validate(dir)

        assert_equal false, result["passed"]
        assert_equal 127, result["commands"].first["exit_code"]
      end
    end
  end

  def test_stuck_output_reader_is_closed_and_killed
    reader = Class.new do
      attr_reader :killed

      def join(*) = false
      def alive? = true
      def kill = @killed = true
    end.new
    io = Class.new do
      attr_reader :closed

      def closed? = @closed == true
      def close = @closed = true
    end.new

    value = Hive::Patrol::Validator.new.send(:reader_value, reader, io)

    assert_equal [ "", true ], value
    assert reader.killed
    assert io.closed
  end

  def test_output_reader_io_error_degrades_to_empty_output
    reader = Object.new
    reader.define_singleton_method(:join) { |*| raise IOError, "reader closed" }

    assert_equal [ "", false ], Hive::Patrol::Validator.new.send(:reader_value, reader, StringIO.new)
  end

  def test_termination_escalates_to_kill_after_grace_period
    waiter = Struct.new(:pid) do
      def join(*) = false
    end.new(12_345)
    signals = []

    with_replaced_singleton_method(Process, :kill, ->(signal, pid) { signals << [ signal, pid ] }) do
      Hive::Patrol::Validator.new.send(:terminate, waiter)
    end

    assert_equal [ [ "TERM", -12_345 ], [ "KILL", -12_345 ] ], signals
  end

  def test_termination_tolerates_process_disappearing
    waiter = Struct.new(:pid).new(12_345)

    with_replaced_singleton_method(Process, :kill, ->(*) { raise Errno::ESRCH }) do
      assert_nil Hive::Patrol::Validator.new.send(:terminate, waiter)
    end
  end
end
