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

  def test_command_system_error_is_reported_as_127
    with_tmp_dir do |dir|
      open3_singleton = class << Open3; self; end
      original = Open3.method(:capture3)
      open3_singleton.define_method(:capture3) { |*| raise Errno::ENOENT, "bash" }
      result = Hive::Patrol::Validator.new("test" => "anything").validate(dir)

      assert_equal false, result["passed"]
      assert_equal 127, result["commands"].first["exit_code"]
    ensure
      open3_singleton.define_method(:capture3, original) if original
    end
  end
end
