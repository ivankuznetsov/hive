require "test_helper"
require "hive/patrol/validator"

class HivePatrolValidatorTest < Minitest::Test
  include HiveTestHelper

  def test_no_commands_is_not_validatable
    result = Hive::Patrol::Validator.new({}).validate(Dir.pwd)

    assert_equal false, result["passed"]
    assert_equal "no_validation_commands", result["reason"]
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
      result = Hive::Patrol::Validator.new("test" => "pwd >/dev/null").validate(dir)

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
      process_singleton = class << Process; self; end
      original = Process.method(:spawn)
      process_singleton.define_method(:spawn) { |*| raise Errno::ENOENT, "bash" }
      result = Hive::Patrol::Validator.new("test" => "anything").validate(dir)

      assert_equal false, result["passed"]
      assert_equal 127, result["commands"].first["exit_code"]
    ensure
      process_singleton.define_method(:spawn, original) if original
    end
  end
end
