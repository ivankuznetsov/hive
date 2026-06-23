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
      [ %w[run --json], "hive-run", {} ],
      [ %w[approve --json], "hive-approve", {} ],
      [ %w[markers clear --json], "hive-markers-clear", {} ],
      [ %w[drop --json], "hive-drop", {} ],
      [ %w[findings --json], "hive-findings", {} ],
      [ %w[accept-finding --json], "hive-findings", { "operation" => "accept" } ],
      [ %w[reject-finding --json], "hive-findings", { "operation" => "reject" } ],
      [ %w[rebase-status --json], "hive-rebase-status", {} ],
      [ %w[brainstorm --json], "hive-stage-action", { "verb" => "brainstorm" } ],
      [ %w[pr --json], "hive-stage-action", { "verb" => "open-pr" } ]
    ]

    with_tmp_global_config do |home|
      cases.each do |argv, schema, extras|
        out, _err, status = run_hive(home, *argv)

        refute status.success?, "#{argv.join(' ')} should fail"
        assert_equal Hive::ExitCodes::USAGE, status.exitstatus
        payload = JSON.parse(out)
        assert_equal schema, payload["schema"]
        assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch(schema, 1), payload["schema_version"]
        assert_equal false, payload["ok"]
        assert_equal "InvalidTaskPath", payload["error_class"]
        assert_equal "invalid_task_path", payload["error_kind"]
        assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
        extras.each { |key, value| assert_equal value, payload[key] }
      end
    end
  end

  # Bare `hive workflow` (no subcommand) with --json must ride the
  # hive-workflow-new envelope (error_kind "usage"), not Thor's generic arity
  # prose. The sibling `hive workflow new` no-id case raises the command's own
  # UsageError ("missing workflow id"); that arm is verified only as a raised
  # message via `new!` in the unit suite (test_rejects_reserved_and_invalid_ids),
  # not re-driven through the JSON envelope here.
  def test_bare_workflow_json_usage_error_uses_workflow_new_envelope
    with_tmp_global_config do |home|
      out, _err, status = run_hive(home, "workflow", "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "hive-workflow-new", payload["schema"]
      assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-workflow-new"), payload["schema_version"]
      assert_equal false, payload["ok"]
      assert_equal "UsageError", payload["error_class"]
      assert_equal "usage", payload["error_kind"]
      assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
      assert_equal "missing SUBCOMMAND (expected: new)", payload["message"]
      assert_equal [ "new" ], payload["expected"]
    end
  end

  def test_bare_workflow_human_usage_error_names_expected_subcommand
    with_tmp_global_config do |home|
      out, err, status = run_hive(home, "workflow")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      assert_empty out
      assert_equal "hive workflow: missing SUBCOMMAND (expected: new)\n", err
    end
  end

  # `hive workflow a b c` (too many positionals) is rejected by Thor *before*
  # command dispatch, so it never reaches the command's own UsageError. With
  # --json it must still ride the hive-workflow-new envelope via the bin/hive
  # "workflow" usage-error contract (error_kind "usage", exit 64,
  # error_class "InvalidTaskPath") — not plain Thor arity prose on stderr.
  # This is the sole reason the "workflow" entry exists in
  # JSON_USAGE_ERROR_CONTRACTS; without this assertion a regression dropping
  # the contract entry would silently revert to bare stderr with no failing test.
  def test_too_many_positionals_workflow_json_usage_error_uses_workflow_new_envelope
    with_tmp_global_config do |home|
      out, _err, status = run_hive(home, "workflow", "a", "b", "c", "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "hive-workflow-new", payload["schema"]
      assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-workflow-new"), payload["schema_version"]
      assert_equal false, payload["ok"]
      assert_equal "InvalidTaskPath", payload["error_class"]
      assert_equal "usage", payload["error_kind"]
      assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
    end
  end

  def test_patrol_missing_project_json_usage_error_uses_patrol_envelope
    with_tmp_global_config do |home|
      out, _err, status = run_hive(home, "patrol", "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "hive-patrol", payload["schema"]
      assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-patrol"), payload["schema_version"]
      assert_equal false, payload["ok"]
      assert_equal "InvalidTaskPath", payload["error_class"]
      assert_equal "error", payload["error_kind"]
      assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
    end
  end
end
