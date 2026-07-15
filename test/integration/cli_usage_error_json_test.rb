require "test_helper"
require "json"
require "json_schemer"
require "open3"
require "rbconfig"

class CliUsageErrorJsonTest < Minitest::Test
  include HiveTestHelper

  HIVE_BIN = File.expand_path("../../bin/hive", __dir__)

  # Thor's exact two-line arity error for `hive workflow a b c` (too many
  # positionals), rejected before command dispatch. Shared by the --json and
  # human-mode arity tests below so a Thor upgrade or a `desc "workflow
  # SUBCOMMAND [REFERENCE]"` reword updates one literal, not two. Each call site keeps
  # its own intentional pin: `.chomp` for the JSON `message` field, the trailing
  # newline as-is for the human stderr stream.
  THOR_WORKFLOW_ARITY_PROSE = <<~MSG.freeze
    ERROR: "hive workflow" was called with arguments ["a", "b", "c"]
    Usage: "hive workflow SUBCOMMAND [REFERENCE]"
  MSG

  def run_hive(home, *args)
    Open3.capture3({ "HIVE_HOME" => home }, RbConfig.ruby, "-Ilib", HIVE_BIN, *args)
  end

  def assert_pre_dispatch_error(home, argv, schema:, error_kind:)
    out, _err, status = run_hive(home, *argv)

    refute status.success?, "#{argv.inspect} should fail"
    assert_equal Hive::ExitCodes::USAGE, status.exitstatus
    payload = JSON.parse(out)
    assert_equal schema, payload["schema"]
    assert_equal false, payload["ok"]
    if schema == "hive-metrics-rollback-rate"
      refute payload.key?("error_class"), "the metrics v1 error schema has no error_class field"
    else
      assert_equal "InvalidTaskPath", payload["error_class"]
    end
    assert_equal error_kind, payload["error_kind"]
    assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]

    if Hive::Schemas::SCHEMA_VERSIONS.key?(schema)
      assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch(schema), payload["schema_version"]
      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(schema))))
      assert_empty schemer.validate(payload).map { |error| error["error"] },
                   "#{argv.inspect} envelope must validate against #{schema}"
    else
      refute payload.key?("schema_version"), "#{schema} is an unversioned legacy envelope"
    end
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

  def test_screenote_commands_json_usage_errors_emit_unversioned_envelopes
    with_tmp_global_config do |home|
      [
        [ %w[connect --json], /Usage: "hive connect SERVICE"/ ],
        [ %w[disconnect --json], /Usage: "hive disconnect SERVICE"/ ]
      ].each do |argv, message_pattern|
        out, err, status = run_hive(home, *argv)

        refute status.success?, "#{argv.join(' ')} should fail"
        assert_equal Hive::ExitCodes::USAGE, status.exitstatus
        payload = JSON.parse(out)
        assert_equal false, payload["ok"]
        assert_equal "screenote", payload["service"]
        assert_equal "InvalidTaskPath", payload["error_class"]
        assert_equal "usage", payload["error_kind"]
        assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
        assert_match message_pattern, payload["message"]
        refute payload.key?("schema"), "Screenote connect/disconnect JSON failures are unversioned"
        assert_match(/^hive: ERROR: /, err.lines.first)
      end
    end
  end

  def test_merged_pr_digest_json_usage_errors_use_merged_pr_schema
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-merged-pr-digest"))))
    cases = [
      %w[digest --source merged-prs --bad --json],
      %w[digest --repo owner/repo --bad --json]
    ]

    with_tmp_global_config do |home|
      cases.each do |argv|
        out, _err, status = run_hive(home, *argv)

        refute status.success?, "#{argv.join(' ')} should fail"
        assert_equal Hive::ExitCodes::USAGE, status.exitstatus
        payload = JSON.parse(out)
        assert_equal "hive-merged-pr-digest", payload["schema"]
        assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-merged-pr-digest"), payload["schema_version"]
        assert_equal false, payload["ok"]
        assert_equal "InvalidTaskPath", payload["error_class"]
        assert_equal "usage", payload["error_kind"]
        assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
        assert_empty schemer.validate(payload).map { |e| e["error"] },
                     "#{argv.join(' ')} envelope must validate against hive-merged-pr-digest schema"
      end
    end
  end

  def test_setup_extra_positional_json_usage_error_uses_setup_envelope
    with_tmp_global_config do |home|
      out, err, status = run_hive(home, "setup", "extra", "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "hive-setup", payload["schema"]
      refute payload.key?("schema_version"), "hive-setup JSON is unversioned"
      assert_equal false, payload["ok"]
      assert_equal "InvalidTaskPath", payload["error_class"]
      assert_equal "usage", payload["error_kind"]
      assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
      assert_match(/Usage: "hive setup"/, payload["message"])
      assert_match(/^hive: ERROR: /, err.lines.first)
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
      expected = %w[new install list update remove]
      assert_equal "missing SUBCOMMAND (expected: #{expected.join(', ')})", payload["message"]
      assert_equal expected, payload["expected"]
    end
  end

  def test_bare_workflow_human_usage_error_names_expected_subcommand
    with_tmp_global_config do |home|
      out, err, status = run_hive(home, "workflow")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      assert_empty out
      assert_equal "hive workflow: missing SUBCOMMAND (expected: new, install, list, update, remove)\n", err
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
      assert_equal THOR_WORKFLOW_ARITY_PROSE.chomp, payload["message"]
      # Argv-shape (Thor) errors ride the envelope but never gain the
      # in-command UsageError discovery fields — those come only from the
      # command's own raise path (bare `hive workflow`), not the bin/hive
      # contract that wraps Thor's arity error.
      refute payload.key?("expected"), "Thor arity errors must not carry `expected`"
      refute payload.key?("value"), "Thor arity errors must not carry `value`"
    end
  end

  # Human-mode (non-`--json`) sibling of the case above. bin/hive branches its
  # stderr prefix on whether a JSON envelope was emitted (`hive: ...` only when
  # JSON rode out); without --json the raw Thor arity prose must surface on
  # stderr with empty stdout (exit 64). Guards that prefix branch and the Thor
  # arity message against a silent regression.
  def test_too_many_positionals_workflow_human_usage_error_emits_thor_arity_prose
    with_tmp_global_config do |home|
      out, err, status = run_hive(home, "workflow", "a", "b", "c")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      assert_empty out
      assert_equal THOR_WORKFLOW_ARITY_PROSE, err
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

  def test_bot_json_usage_errors_emit_bot_envelopes
    # Every bot --json usage error rides the hive-bot-status schema with
    # ok:false; validate each emitted payload against the published schema so
    # a schema-conforming agent client would actually accept it (the
    # ErrorPayload arm regression that produced an unvalidatable envelope).
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-bot-status"))))
    with_tmp_global_config do |home|
      out, err, status = run_hive(home, "bot", "status", "--force", "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "hive-bot-status", payload["schema"]
      assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-bot-status"), payload["schema_version"]
      assert_equal false, payload["ok"]
      assert_equal "wrong_subcommand_flag", payload["error_kind"]
      assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
      assert_match(/--force only applies/, payload["message"])
      assert_match(/^hive: hive bot status: --force only applies/, err.lines.last)
      assert_empty schemer.validate(payload).map { |e| e["error"] },
                   "bot status --force --json envelope must validate against hive-bot-status schema"

      out, err, status = run_hive(home, "bot", "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "hive-bot-status", payload["schema"]
      assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-bot-status"), payload["schema_version"]
      assert_equal false, payload["ok"]
      assert_equal "missing_subcommand", payload["error_kind"]
      assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
      assert_match(/missing SUBCOMMAND/, payload["message"])
      assert_match(/^hive: hive bot: missing SUBCOMMAND/, err.lines.last)
      assert_empty schemer.validate(payload).map { |e| e["error"] },
                   "bot --json envelope must validate against hive-bot-status schema"

      out, err, status = run_hive(home, "bot", "unknown", "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      payload = JSON.parse(out)
      assert_equal "hive-bot-status", payload["schema"]
      assert_equal false, payload["ok"]
      assert_equal "unknown_subcommand", payload["error_kind"]
      assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
      assert_match(/unknown subcommand "unknown"/, payload["message"])
      assert_match(/^hive: hive bot: unknown subcommand "unknown"/, err.lines.last)
      assert_empty schemer.validate(payload).map { |e| e["error"] },
                   "bot unknown --json envelope must validate against hive-bot-status schema"
    end
  end

  # `hive bot SUBCOMMAND` takes a single positional and (unlike `daemon`) has no
  # `*targets` splat, so an extra positional such as `hive bot status extra` is
  # rejected by Thor *before* `Hive::Commands::Bot#call` runs — bypassing the
  # command-level usage-error emitters. With --json it must still ride the
  # hive-bot-status envelope via the bin/hive "bot" usage-error contract
  # (error_kind "extra_arguments", error_class "InvalidTaskPath", exit 64), not
  # bare Thor arity prose on stderr. This is the sole reason the resolver has a
  # dedicated `bot` branch in json_usage_error_contract.
  def test_bot_extra_positional_json_usage_error_rides_bot_status_envelope
    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-bot-status"))))
    with_tmp_global_config do |home|
      [ %w[bot status extra --json], %w[bot install extra --json] ].each do |argv|
        out, err, status = run_hive(home, *argv)

        refute status.success?, "#{argv.join(' ')} should fail"
        assert_equal Hive::ExitCodes::USAGE, status.exitstatus
        payload = JSON.parse(out)
        assert_equal "hive-bot-status", payload["schema"]
        assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-bot-status"), payload["schema_version"]
        assert_equal false, payload["ok"]
        assert_equal "InvalidTaskPath", payload["error_class"]
        assert_equal "extra_arguments", payload["error_kind"]
        assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
        assert_match(/was called with arguments/, payload["message"])
        assert_match(/^hive: ERROR: /, err.lines.first)
        assert_empty schemer.validate(payload).map { |e| e["error"] },
                     "#{argv.join(' ')} envelope must validate against hive-bot-status schema"
      end
    end
  end

  # Human-mode (non-`--json`) sibling: without --json the raw Thor arity prose
  # must surface on stderr with empty stdout (exit 64), guarding bin/hive's
  # stderr-prefix branch against a silent regression.
  def test_bot_extra_positional_human_usage_error_emits_thor_arity_prose
    with_tmp_global_config do |home|
      out, err, status = run_hive(home, "bot", "status", "extra")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      assert_empty out
      assert_match(/was called with arguments \["status", "extra"\]/, err)
    end
  end

  def test_documented_json_surfaces_wrap_thor_arity_errors
    cases = [
      [ %w[status extra --json], "hive-status", "error" ],
      [ %w[status --diagnose task extra --json], "hive-status-diagnose", "error" ],
      [ %w[status --json -- extra --diagnose=task], "hive-status", "error" ],
      [ %w[prune extra --json], "hive-prune", "usage" ],
      [ %w[forget project extra --json], "hive-forget", "usage" ],
      [ %w[metrics rollback-rate extra --json], "hive-metrics-rollback-rate", "error" ],
      [ %w[web status extra --json], "hive-web-status", "invalid_task_path" ],
      [ %w[web install extra --json], "hive-web-install", "invalid_task_path" ],
      [ %w[web --bind install status extra --json], "hive-web-status", "invalid_task_path" ],
      [ %w[digest extra --json], "hive-digest", "usage" ],
      [ %w[digest --json -- extra --source merged-prs], "hive-digest", "usage" ],
      [ %w[digest --source merged-prs extra --json], "hive-merged-pr-digest", "usage" ]
    ]

    with_tmp_global_config do |home|
      cases.each do |argv, schema, error_kind|
        assert_pre_dispatch_error(home, argv, schema: schema, error_kind: error_kind)
      end
    end
  end

  def test_invalid_byte_errors_use_the_selected_json_surface
    invalid = "bad\xFF".b
    cases = [
      [ [ "status", "--diagnose", "task", "--json", invalid ], "hive-status-diagnose", "error" ],
      [ [ "web", "status", "--json", invalid ], "hive-web-status", "invalid_task_path" ],
      [ [ "bot", "status", "--json", invalid ], "hive-bot-status", "extra_arguments" ],
      [ [ "pairing", "list", "--json", invalid ], "hive-pairing-list", "invalid_arguments" ],
      [ [ "pairing", "unknown", "approve", "--json", invalid ],
        "hive-pairing-list", "invalid_arguments" ],
      [ [ "pairing", "approve", "telegram", "CODE", "--json", invalid ],
        "hive-pairing-approve", "invalid_arguments" ],
      [ [ "digest", "--json", invalid ], "hive-digest", "usage" ],
      [ [ "digest", "--source", invalid, "--json" ], "hive-digest", "usage" ],
      [ [ "digest", "--source", "merged-prs", "--json", invalid ],
        "hive-merged-pr-digest", "usage" ]
    ]

    with_tmp_global_config do |home|
      cases.each do |argv, schema, error_kind|
        assert_pre_dispatch_error(home, argv, schema: schema, error_kind: error_kind)
      end
    end
  end

  def test_invalid_command_encoding_is_not_attributed_to_a_later_command
    with_tmp_global_config do |home|
      out, err, status = run_hive(home, "bad\xFF".b, "status", "--json")

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      assert_empty out
      assert_match(/invalid byte sequence/, err)
    end
  end

  def test_invalid_byte_json_arg_uses_command_usage_envelope
    with_tmp_global_config do |home|
      out, err, status = run_hive(home, "run", "--json", "bad\xFF".b)

      refute status.success?
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
      refute_match(%r{/thor/}, err)
      payload = JSON.parse(out)
      assert_equal "hive-run", payload["schema"]
      assert_equal Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-run"), payload["schema_version"]
      assert_equal false, payload["ok"]
      assert_equal "InvalidTaskPath", payload["error_class"]
      assert_equal "invalid_task_path", payload["error_kind"]
      assert_equal Hive::ExitCodes::USAGE, payload["exit_code"]
      assert_match(/invalid byte sequence/, payload["message"])
    end
  end
end
