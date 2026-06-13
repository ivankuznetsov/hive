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

  def test_bin_hive_json_usage_errors_cover_documented_required_arg_commands
    [
      [ %w[drop --json], "hive-drop", "invalid_task_path", {} ],
      [ %w[findings --json], "hive-findings", "invalid_task_path", {} ],
      [ %w[rebase-status --json], "hive-rebase-status", "invalid_task_path", {} ],
      [ %w[plan --json], "hive-stage-action", "invalid_task_path", { "verb" => "plan" } ]
    ].each do |argv, schema, error_kind, extras|
      out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "bin/hive", *argv)

      assert_equal Hive::ExitCodes::USAGE, status.exitstatus, "#{argv.join(' ')} should exit 64"
      payload = JSON.parse(out)
      assert_equal schema, payload["schema"]
      if Hive::Schemas::SCHEMA_VERSIONS.key?(schema)
        assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch(schema), payload["schema_version"]
      else
        refute payload.key?("schema_version")
      end
      assert_equal false, payload["ok"]
      assert_equal error_kind, payload["error_kind"]
      assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
      extras.each { |key, value| assert_equal value, payload[key] }
      assert_match(/called with no arguments/, payload["message"])
      assert_match(/^hive: /, err)
    end
  end

  private

  def without_generated_at(payload)
    payload.reject { |key, _value| key == "generated_at" }
  end
end
