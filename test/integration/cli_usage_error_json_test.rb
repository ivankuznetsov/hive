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
      [ %w[run --json], "hive-run", "invalid_task_path", {} ],
      [ %w[approve --json], "hive-approve", "invalid_task_path", {} ],
      [ %w[markers clear --json], "hive-markers-clear", "invalid_task_path", {} ],
      [ %w[brainstorm --json], "hive-stage-action", "invalid_task_path", { "verb" => "brainstorm" } ],
      [ %w[pr --json], "hive-stage-action", "invalid_task_path", { "verb" => "open-pr" } ],
      [ %w[drop --json], "hive-drop", "invalid_task_path", {} ],
      [ %w[findings --json], "hive-findings", "invalid_task_path", {} ],
      [ %w[accept-finding --json], "hive-findings", "invalid_task_path", { "operation" => "accept" } ],
      [ %w[reject-finding --json], "hive-findings", "invalid_task_path", { "operation" => "reject" } ],
      [ %w[patrol --json], "hive-patrol", "error", {} ],
      [ %w[status --bogus --json], "hive-status", "error", {} ],
      [ %w[prune --bogus --json], "hive-prune", "usage", {} ]
    ]

    with_tmp_global_config do |home|
      cases.each do |argv, schema, error_kind, extras|
        out, _err, status = run_hive(home, *argv)

        refute status.success?, "#{argv.join(' ')} should fail"
        assert_equal Hive::ExitCodes::USAGE, status.exitstatus
        payload = JSON.parse(out)
        assert_equal schema, payload["schema"]
        assert_equal false, payload["ok"]
        assert_equal "InvalidTaskPath", payload["error_class"]
        assert_equal error_kind, payload["error_kind"]
        assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
        extras.each do |key, value|
          assert_equal value, payload[key]
        end
      end
    end
  end
end
