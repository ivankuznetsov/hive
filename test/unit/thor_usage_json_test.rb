require "test_helper"
require "json"
require "stringio"
require "json_schemer"
require "hive/thor_usage_json"

# Direct unit coverage for the parse-error envelope builder extracted from
# `bin/hive`. These pin behavior the integration suite can only reach
# through a subprocess: the build->validate round-trip over EVERY mapped
# entry (not just the 14 that raise on a missing positional), flag-order
# independence of command/`--json` detection, and the EPIPE /
# GeneratorError write-failure branches.
class HiveThorUsageJsonTest < Minitest::Test
  ThorUsageJson = Hive::ThorUsageJson

  # The single highest-value guard: every mapped envelope must build a
  # document that validates against its published schema, including the
  # otherwise-untested `forget`/`prune`/`status`/`patrol`/`daemon`/`archive`
  # rows. A future edit to any schema's `error_kind` enum (or a typo'd
  # mapped kind) fails here even though those rows never fire in practice.
  def test_every_mapped_envelope_builds_a_schema_valid_document
    ThorUsageJson::ENVELOPES.each do |command, envelope|
      error = Hive::UsageError.new("boom", error_kind: envelope.error_kind)
      payload = ThorUsageJson.build_payload(error, envelope)

      assert_equal envelope.schema, payload.fetch("schema"),
                   "`#{command}` must claim its mapped schema"
      assert_equal envelope.error_kind, payload.fetch("error_kind")

      schemer = JSONSchemer.schema(JSON.parse(File.read(Hive::Schemas.schema_path(envelope.schema))))
      assert schemer.valid?(payload),
             "`#{command}` envelope must validate against #{envelope.schema} " \
             "(errors: #{schemer.validate(payload).map { |e| e['error'] }.inspect})"
    end
  end

  # Mirrors the module's load-time guard: a routed schema missing from
  # SCHEMA_VERSIONS would make `ErrorEnvelope.build`'s fetch raise a
  # KeyError on the --json path — neither Thor nor Hive error, so it would
  # escape the top-level rescue as a raw backtrace.
  def test_all_mapped_schemas_are_registered_in_schema_versions
    ThorUsageJson::ENVELOPES.each_value do |envelope|
      assert_includes Hive::Schemas::SCHEMA_VERSIONS.keys, envelope.schema,
                      "#{envelope.schema} must be registered so ErrorEnvelope.build cannot KeyError"
    end
  end

  def test_command_token_is_flag_order_independent
    assert_equal "run", ThorUsageJson.command_token([ "run", "--json" ])
    assert_equal "run", ThorUsageJson.command_token([ "--json", "run" ])
    assert_nil ThorUsageJson.command_token([ "--json", "--verbose" ])
  end

  def test_json_requested_detects_the_flag_in_any_position
    assert ThorUsageJson.json_requested?([ "run", "--json" ])
    assert ThorUsageJson.json_requested?([ "--json", "run" ])
    refute ThorUsageJson.json_requested?([ "run" ])
  end

  def test_emit_writes_a_routable_envelope_for_a_mapped_command
    io = StringIO.new
    ThorUsageJson.emit([ "run", "--json" ], RuntimeError.new("no args"), io: io, warn_io: StringIO.new)

    payload = JSON.parse(io.string)
    assert_equal "hive-run", payload.fetch("schema")
    assert_equal "invalid_task_path", payload.fetch("error_kind")
    assert_equal false, payload.fetch("ok")
  end

  def test_emit_writes_a_schemaless_usage_envelope_for_an_unknown_command
    io = StringIO.new
    ThorUsageJson.emit([ "boguscmd", "--json" ], RuntimeError.new("Could not find command"),
                       io: io, warn_io: StringIO.new)

    payload = JSON.parse(io.string)
    refute payload.key?("schema"), "an unknown command has no versioned schema to route under"
    assert_equal "usage", payload.fetch("error_kind")
    assert_equal "UsageError", payload.fetch("error_class")
    assert_equal Hive::ExitCodes::USAGE, payload.fetch("exit_code")
  end

  def test_emit_swallows_epipe_from_a_closed_downstream
    io = Object.new
    def io.puts(*) = raise Errno::EPIPE
    warn_io = StringIO.new

    # Must not propagate: a downstream that closed the pipe is not our
    # failure to report.
    ThorUsageJson.emit([ "run", "--json" ], RuntimeError.new("no args"), io: io, warn_io: warn_io)

    assert_empty warn_io.string, "EPIPE on the write path is silent, not a warning"
  end

  def test_emit_warns_both_messages_on_a_json_generator_error
    io = Object.new
    def io.puts(*) = raise JSON::GeneratorError, "unencodable"
    warn_io = StringIO.new

    ThorUsageJson.emit([ "run", "--json" ], RuntimeError.new("original usage text"),
                       io: io, warn_io: warn_io)

    assert_includes warn_io.string, "original usage text",
                    "the original Thor usage text must still reach the caller"
    assert_includes warn_io.string, "failed to serialise JSON error envelope",
                    "the serialisation failure must be surfaced, not swallowed"
  end
end
