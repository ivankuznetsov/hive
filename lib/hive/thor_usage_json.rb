require "json"
require "hive"

module Hive
  # Builds the contract-valid `--json` error document for Thor parse
  # errors (missing required positional, unknown flag) that fire *before*
  # a command body runs. Extracted from `bin/hive` so the per-command
  # schema routing, the command/flag detection, and the write-path
  # failure handling are unit-testable directly rather than reachable
  # only through a subprocess.
  module ThorUsageJson
    module_function

    STAGE_ACTION_SCHEMA = "hive-stage-action".freeze

    # One routing row per command whose `--json` parse-error envelope must
    # mirror what the command's own emitter would produce. `extras` carries
    # any schema-*required* field the in-command emitter supplies (e.g.
    # `hive-stage-action`'s `verb`); `nil` means the schema needs none. The
    # labeled struct keeps the optional third slot and the `verb`
    # requirement self-documenting and lets the load-time guard below scan
    # `schema` by name.
    Envelope = Struct.new(:schema, :error_kind, :extras, keyword_init: true) do
      def extras_hash
        extras || {}
      end
    end

    # The `hive-stage-action` `verb` enum keys off the canonical verb, not
    # the invoked alias: `hive pr` dispatches the `open-pr` verb.
    def stage_action_envelope(verb)
      Envelope.new(schema: STAGE_ACTION_SCHEMA, error_kind: "invalid_task_path", extras: { "verb" => verb })
    end

    ENVELOPES = {
      "run" => Envelope.new(schema: "hive-run", error_kind: "invalid_task_path"),
      "approve" => Envelope.new(schema: "hive-approve", error_kind: "invalid_task_path"),
      "findings" => Envelope.new(schema: "hive-findings", error_kind: "invalid_task_path"),
      "accept-finding" => Envelope.new(schema: "hive-findings", error_kind: "invalid_task_path"),
      "reject-finding" => Envelope.new(schema: "hive-findings", error_kind: "invalid_task_path"),
      "brainstorm" => stage_action_envelope("brainstorm"),
      "plan" => stage_action_envelope("plan"),
      "develop" => stage_action_envelope("develop"),
      "open-pr" => stage_action_envelope("open-pr"),
      "pr" => stage_action_envelope("open-pr"),
      "review" => stage_action_envelope("review"),
      "artifacts" => stage_action_envelope("artifacts"),
      "finalize" => stage_action_envelope("finalize"),
      # Retained defensively. `hive archive` accepts a bare invocation, so
      # it never raises a Thor *parse* error and this row is unreachable in
      # practice — but if `archive` ever gains a required positional, the
      # row keeps its parse-error envelope contract-correct out of the box.
      "archive" => stage_action_envelope("archive"),
      "drop" => Envelope.new(schema: "hive-drop", error_kind: "invalid_task_path"),
      "markers" => Envelope.new(schema: "hive-markers-clear", error_kind: "invalid_task_path"),
      # Retained defensively. `forget`/`daemon` raise their own
      # command-local `UsageError < Hive::Error` from inside the command
      # body, caught by `bin/hive`'s lower `rescue Hive::Error`, so neither
      # row fires today. Kept so a future refactor that routes one through
      # the Thor parse path still emits a contract-valid envelope.
      "forget" => Envelope.new(schema: "hive-forget", error_kind: "missing_name"),
      "prune" => Envelope.new(schema: "hive-prune", error_kind: "usage"),
      "status" => Envelope.new(schema: "hive-status", error_kind: "error"),
      "patrol" => Envelope.new(schema: "hive-patrol", error_kind: "error"),
      "daemon" => Envelope.new(schema: "hive-daemon-enroll", error_kind: "missing_project")
    }.freeze

    # Load-time guard: every routed schema must exist in
    # `SCHEMA_VERSIONS`. Without it, a future typo'd schema string would
    # only surface as a `KeyError` from `ErrorEnvelope.build`'s
    # `SCHEMA_VERSIONS.fetch` *on the --json path* — neither `Thor::Error`
    # nor `Hive::Error`, so it would escape `bin/hive`'s top-level rescue
    # and print a raw backtrace, the exact agent-hostile failure this code
    # exists to prevent. Failing at boot instead makes the typo loud.
    unknown_schemas = ENVELOPES.values.map(&:schema) - Hive::Schemas::SCHEMA_VERSIONS.keys
    unless unknown_schemas.empty?
      raise "Hive::ThorUsageJson: unknown schema(s) not in SCHEMA_VERSIONS: #{unknown_schemas.inspect}"
    end

    # The command token is the first non-flag argv element, so detection
    # is independent of flag ordering (`hive --json run` -> `run`).
    def command_token(argv)
      argv.find { |arg| !arg.start_with?("-") }
    end

    # `--json` is a boolean flag, so a bare token match is order-independent
    # (`hive --json run` and `hive run --json` both request JSON). Known
    # limitation: a literal `--json` supplied as another option's *value*
    # would also match; the parse-error envelope is still well-formed in
    # that case, so we accept the false-positive rather than reimplement
    # Thor's option parser here.
    def json_requested?(argv)
      argv.include?("--json")
    end

    # Emit the parse-error document for `argv`/`error` to `io`. `io`/`warn_io`
    # are injectable so the EPIPE and GeneratorError write-failure branches
    # are testable without a subprocess.
    def emit(argv, error, io: $stdout, warn_io: $stderr)
      envelope = ENVELOPES[command_token(argv)]
      error_kind = envelope&.error_kind || "usage"
      usage_error = Hive::UsageError.new(error.message, error_kind: error_kind)

      io.puts(JSON.generate(build_payload(usage_error, envelope)))
    rescue Errno::EPIPE
      # Downstream closed the pipe before we finished writing — nothing
      # more we can do, and the broken pipe is not our failure to report.
    rescue JSON::GeneratorError => e
      # The envelope itself could not be serialised (a real defect). Don't
      # exit silently with empty stdout: surface both the serialisation
      # failure and the original Thor usage text so the caller still learns
      # what they typed wrong.
      warn_io.puts(error.message)
      warn_io.puts("hive: failed to serialise JSON error envelope: #{e.message}")
    end

    def build_payload(usage_error, envelope)
      if envelope
        Hive::Schemas::ErrorEnvelope.build(
          schema: envelope.schema,
          error: usage_error,
          error_kind: usage_error.error_kind,
          extras: envelope.extras_hash
        )
      else
        # No versioned schema exists for an unknown/typo'd command (or a
        # command without a `--json` contract), so we cannot route under a
        # `schema` key — but keep the rest of the shape consistent with
        # `ErrorEnvelope.build` (same last-`::`-segment `error_class`) and
        # use the semantically-correct `usage` kind rather than the
        # misleading `invalid_task_path`.
        {
          "ok" => false,
          "error_class" => usage_error.class.name.split("::").last,
          "error_kind" => usage_error.error_kind,
          "exit_code" => Hive::ExitCodes::USAGE,
          "message" => usage_error.message
        }
      end
    end
  end
end
