require "test_helper"
require "json"
require "json_schemer"
require "open3"
require "rbconfig"

class CliParseErrorTest < Minitest::Test
  HIVE_BIN = File.expand_path("../../bin/hive", __dir__)

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

  def test_unknown_command_exits_usage
    out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", HIVE_BIN, "frobnicate")

    assert_equal Hive::ExitCodes::USAGE, status.exitstatus
    assert_empty out
    assert_includes err, "Could not find command"
  end
end
