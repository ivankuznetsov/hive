require "test_helper"
require "json"
require "json_schemer"
require "open3"
require "rbconfig"

class CliParseErrorTest < Minitest::Test
  HIVE_BIN = File.expand_path("../../bin/hive", __dir__)

  # Every command whose `--json` parse-error envelope must validate against
  # its published schema. Each entry is the invoked command paired with the
  # schema name the emitted envelope claims; running `hive <command> --json`
  # with no positional reliably raises a Thor parse error (the positional is
  # required), routing through `emit_thor_usage_json`. A bare round-trip
  # ("build envelope -> validate against schemas/<schema>.v*.json") over the
  # whole set is the single highest-value guard: it pins the per-command
  # schema mapping and, critically, the `hive-stage-action` `verb` extra that
  # the ErrorPayload schema requires (a missing `verb` fails validation here).
  PARSE_ERROR_COMMANDS = {
    "run" => "hive-run",
    "approve" => "hive-approve",
    "findings" => "hive-findings",
    "accept-finding" => "hive-findings",
    "reject-finding" => "hive-findings",
    "brainstorm" => "hive-stage-action",
    "plan" => "hive-stage-action",
    "develop" => "hive-stage-action",
    "open-pr" => "hive-stage-action",
    "pr" => "hive-stage-action",
    "review" => "hive-stage-action",
    "artifacts" => "hive-stage-action",
    "finalize" => "hive-stage-action",
    "drop" => "hive-drop",
    "markers" => "hive-markers-clear"
  }.freeze
  # NOTE: `forget`/`prune`/`status`/`patrol`/`daemon`/`archive` are absent on
  # purpose — they accept the bare invocation (optional positional or a
  # subcommand group) and so never raise a Thor *parse* error. `forget`'s
  # missing-NAME case is a Hive::Error raised inside the command, emitted by
  # its own EnvelopeEmitter, not by `emit_thor_usage_json`.

  def test_parse_error_envelopes_validate_against_their_schemas
    PARSE_ERROR_COMMANDS.each do |command, schema_name|
      out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", HIVE_BIN, command, "--json")

      assert_equal Hive::ExitCodes::USAGE, status.exitstatus,
                   "`hive #{command} --json` must exit USAGE on a parse error"
      assert_empty err, "`hive #{command} --json` must not write to stderr on the JSON path"

      payload = JSON.parse(out)
      assert_equal schema_name, payload.fetch("schema"),
                   "`hive #{command} --json` must claim the #{schema_name} schema"
      assert_equal false, payload.fetch("ok")

      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(schema_name))))
      assert schemer.valid?(payload),
             "`hive #{command} --json` parse-error envelope must validate against #{schema_name} " \
             "(errors: #{schemer.validate(payload).map { |e| e['error'] }.inspect})"
    end
  end

  def test_stage_action_parse_error_carries_canonical_verb
    # `hive pr` is an alias for the `open-pr` verb; the envelope must report
    # the canonical verb name the schema enum lists, not the invoked alias.
    out, _err, status = Open3.capture3(RbConfig.ruby, "-Ilib", HIVE_BIN, "pr", "--json")

    assert_equal Hive::ExitCodes::USAGE, status.exitstatus
    payload = JSON.parse(out)
    assert_equal "open-pr", payload.fetch("verb"),
                 "`hive pr` must map to the canonical `open-pr` verb in its parse-error envelope"
  end

  def test_unknown_command_json_emits_routable_usage_envelope
    out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", HIVE_BIN, "boguscmd", "--json")

    assert_equal Hive::ExitCodes::USAGE, status.exitstatus
    assert_empty err

    payload = JSON.parse(out)
    assert_equal false, payload.fetch("ok")
    # No versioned schema exists for an unknown command, but the kind must be
    # the semantically-correct `usage` (not the misleading `invalid_task_path`)
    # and the error_class must use the same last-`::`-segment form as the
    # schema-bearing branch.
    assert_equal "usage", payload.fetch("error_kind")
    assert_equal "UsageError", payload.fetch("error_class")
    assert_equal Hive::ExitCodes::USAGE, payload.fetch("exit_code")
    assert_includes payload.fetch("message"), "Could not find command"
  end

  def test_missing_required_positional_json_uses_usage_envelope
    out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", HIVE_BIN, "run", "--json")

    assert_equal Hive::ExitCodes::USAGE, status.exitstatus
    assert_empty err

    payload = JSON.parse(out)
    assert_equal "hive-run", payload.fetch("schema")
    assert_equal false, payload.fetch("ok")
    assert_equal "invalid_task_path", payload.fetch("error_kind")
    assert_equal Hive::ExitCodes::USAGE, payload.fetch("exit_code")
    assert_includes payload.fetch("message"), "no arguments"

    schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path("hive-run"))))
    assert schemer.valid?(payload),
           "parse error envelope must validate (errors: #{schemer.validate(payload).map { |e| e['error'] }.inspect})"
  end

  # `status` and `prune` accept a bare invocation (no required positional),
  # so they are absent from PARSE_ERROR_COMMANDS — but an *unknown flag*
  # still makes Thor raise before the command body runs, routing them
  # through `emit_thor_usage_json`. These rows were previously untested
  # (wiki/gaps.md #24); pin that the routed envelope is contract-valid.
  UNKNOWN_FLAG_THOR_ROUTED = {
    "status" => "hive-status",
    "prune" => "hive-prune"
  }.freeze

  def test_unknown_flag_on_bare_invocation_commands_routes_through_usage_json
    UNKNOWN_FLAG_THOR_ROUTED.each do |command, schema_name|
      out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", HIVE_BIN, command, "--bogus", "--json")

      assert_equal Hive::ExitCodes::USAGE, status.exitstatus,
                   "`hive #{command} --bogus --json` must exit USAGE on the unknown-flag parse error"
      assert_empty err, "`hive #{command} --bogus --json` must not write to stderr on the JSON path"

      payload = JSON.parse(out)
      assert_equal schema_name, payload.fetch("schema")
      assert_equal false, payload.fetch("ok")

      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(schema_name))))
      assert schemer.valid?(payload),
             "`hive #{command} --bogus --json` envelope must validate against #{schema_name} " \
             "(errors: #{schemer.validate(payload).map { |e| e['error'] }.inspect})"
    end
  end

  def test_daemon_unknown_subcommand_is_a_dead_map_entry_emitting_stderr
    # The `daemon` map row is retained defensively but unreachable: an
    # unknown daemon subcommand raises a command-local Hive::Error caught
    # by bin/hive's *lower* `rescue Hive::Error`, so no stdout JSON
    # envelope is built from the map. Pin that current behavior so a
    # future refactor that routes it through the Thor path (double-emit)
    # is caught.
    out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", HIVE_BIN, "daemon", "--bogus", "--json")

    assert_equal Hive::ExitCodes::USAGE, status.exitstatus
    assert_empty out.strip, "the dead daemon map row must not emit a stdout JSON envelope"
    assert_includes err, "unknown subcommand"
  end

  def test_unknown_command_exits_usage
    out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", HIVE_BIN, "frobnicate")

    assert_equal Hive::ExitCodes::USAGE, status.exitstatus
    assert_empty out
    assert_includes err, "Could not find command"
  end
end
