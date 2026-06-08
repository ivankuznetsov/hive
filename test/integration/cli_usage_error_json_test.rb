require "test_helper"
require "json"
require "open3"
require "rbconfig"

class CliUsageErrorJsonTest < Minitest::Test
  include HiveTestHelper

  HIVE_BIN = File.expand_path("../../bin/hive", __dir__)

  def run_hive(home, *args)
    Open3.capture3({ "HIVE_HOME" => home }, RbConfig.ruby, "-Ilib", HIVE_BIN, *args)
  end

  def test_json_usage_errors_emit_envelopes_before_command_dispatch
    cases = [
      [ %w[run --json], "hive-run" ],
      [ %w[--json=true run], "hive-run" ],
      [ %w[--json=t run], "hive-run" ],
      [ %w[approve --json], "hive-approve" ],
      [ %w[markers clear --json], "hive-markers-clear" ]
    ]

    with_tmp_global_config do |home|
      cases.each do |argv, schema|
        out, _err, status = run_hive(home, *argv)

        refute status.success?, "#{argv.join(' ')} should fail"
        assert_equal Hive::ExitCodes::USAGE, status.exitstatus
        payload = JSON.parse(out)
        assert_equal schema, payload["schema"]
        assert_equal false, payload["ok"]
        assert_equal "InvalidTaskPath", payload["error_class"]
        assert_equal "invalid_task_path", payload["error_kind"]
        assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
      end
    end
  end
end
