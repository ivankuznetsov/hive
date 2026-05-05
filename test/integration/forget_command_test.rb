require "test_helper"
require "json"
require "hive/commands/forget"

# End-to-end coverage for `hive forget NAME`. Drives the command class
# directly. Asserts both the human-readable text path and the --json
# envelope shape, plus the USAGE (64) exit-code contract for unknown
# names — symmetric with `hive metrics --project NAME` so agent
# wrappers can branch on a single canonical error_kind value.
class ForgetCommandTest < Minitest::Test
  include HiveTestHelper

  def test_forget_removes_named_entry_text_output
    with_tmp_global_config do
      Hive::Config.register_project(name: "keep", path: "/tmp/keep")
      Hive::Config.register_project(name: "drop", path: "/tmp/drop")

      out, _err = capture_io { Hive::Commands::Forget.new("drop").call }
      assert_match(/removed drop/, out)
      assert_equal [ "keep" ], Hive::Config.registered_projects.map { |p| p["name"] }
    end
  end

  def test_forget_emits_success_envelope_under_json
    with_tmp_global_config do
      Hive::Config.register_project(name: "drop", path: "/tmp/drop")

      out, _err = capture_io { Hive::Commands::Forget.new("drop", json: true).call }
      payload = JSON.parse(out)
      assert_equal "hive-forget", payload["schema"]
      assert_equal 1, payload["schema_version"]
      assert_equal true, payload["ok"]
      assert_equal "drop", payload["name"]
      assert_equal "/tmp/drop", payload["path"]
      assert_equal "/tmp/drop/.hive-state", payload["hive_state_path"]
    end
  end

  def test_forget_unknown_name_exits_usage
    with_tmp_global_config do
      Hive::Config.register_project(name: "keep", path: "/tmp/keep")

      _out, err, status = with_captured_exit do
        Hive::Commands::Forget.new("ghost").call
      end
      assert_equal Hive::ExitCodes::USAGE, status
      assert_match(/no entry named "ghost"/, err)
      assert_equal [ "keep" ], Hive::Config.registered_projects.map { |p| p["name"] }
    end
  end

  def test_forget_unknown_name_json_emits_error_envelope
    with_tmp_global_config do
      Hive::Config.register_project(name: "keep", path: "/tmp/keep")

      out, _err, status = with_captured_exit do
        Hive::Commands::Forget.new("ghost", json: true).call
      end
      assert_equal Hive::ExitCodes::USAGE, status

      payload = JSON.parse(out)
      assert_equal "hive-forget", payload["schema"]
      assert_equal false, payload["ok"]
      assert_equal "unknown_project", payload["error_kind"]
      assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
      assert_match(/no entry named "ghost"/, payload["message"])
    end
  end

  def test_forget_missing_name_argument_exits_usage
    with_tmp_global_config do
      _out, err, status = with_captured_exit do
        Hive::Commands::Forget.new(nil).call
      end
      assert_equal Hive::ExitCodes::USAGE, status
      assert_match(/missing project NAME/, err)
    end
  end
end
