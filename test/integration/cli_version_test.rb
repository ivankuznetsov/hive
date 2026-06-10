require "test_helper"
require "json"
require "open3"
require "rbconfig"

class CliVersionTest < Minitest::Test
  include HiveTestHelper

  def test_bin_hive_version_outputs_version
    out = run!(RbConfig.ruby, "-Ilib", "bin/hive", "--version")

    assert_equal "#{Hive::VERSION}\n", out
  end

  def test_bin_hive_help_after_option_value_shows_command_usage
    out, err, status = Open3.capture3(
      RbConfig.ruby, "-Ilib", "bin/hive", "approve", "--from", "2-brainstorm", "--help"
    )

    assert status.success?, "bin/hive approve --from 2-brainstorm --help should exit 0, stderr was: #{err}"
    assert_includes out, "Usage:"
    assert_includes out, "approve"
    refute_includes err, "No value provided for required arguments"
  end

  def test_bin_hive_accepts_json_before_status_command
    with_tmp_global_config do
      leading = JSON.parse(run!(RbConfig.ruby, "-Ilib", "bin/hive", "--json", "status"))
      trailing = JSON.parse(run!(RbConfig.ruby, "-Ilib", "bin/hive", "status", "--json"))

      assert_equal without_generated_at(trailing), without_generated_at(leading)
    end
  end

  def test_bin_hive_accepts_leading_json_true_before_status_command
    with_tmp_global_config do
      leading = JSON.parse(run!(RbConfig.ruby, "-Ilib", "bin/hive", "--json=true", "status"))
      trailing = JSON.parse(run!(RbConfig.ruby, "-Ilib", "bin/hive", "status", "--json=true"))

      assert_equal without_generated_at(trailing), without_generated_at(leading)
    end
  end

  def test_bin_hive_rejects_unsupported_json_assignments_before_target_dispatch
    with_tmp_global_config do
      %w[--json=1 --json=yes].each do |flag|
        out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "bin/hive", "run", flag)

        assert_equal 64, status.exitstatus, "#{flag}: malformed JSON flag should be a usage error"
        assert_empty out, "#{flag}: unsupported JSON assignments must not request JSON mode"
        assert_match(/invalid boolean value for --json/, err)
        refute_match(/slug '#{Regexp.escape(flag.split("=", 2).last)}'/, err)
      end
    end
  end

  private

  def without_generated_at(payload)
    payload.reject { |key, _value| key == "generated_at" }
  end
end
