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
      # Keys `ErrorEnvelope.build` owns. `extras` is merged *over* the base
      # payload, so an `extras` row colliding with one of these would let a
      # routing row silently emit a contract-violating envelope (e.g. a
      # rewritten `error_kind`/`exit_code`). Disjointness is asserted in
      # `extras_hash` rather than trusted.
      RESERVED_PAYLOAD_KEYS = %w[schema schema_version ok error_class error_kind exit_code message].freeze

      def extras_hash
        hash = extras || {}
        clash = hash.keys & RESERVED_PAYLOAD_KEYS
        unless clash.empty?
          raise "Hive::ThorUsageJson::Envelope: extras may not override reserved payload keys: #{clash.inspect}"
        end
        hash
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
      # DEAD (defensive): `hive archive` accepts a bare invocation, so it
      # never raises a Thor *parse* error and nothing routes here today —
      # but if `archive` ever gains a required positional, the row keeps
      # its parse-error envelope contract-correct out of the box.
      "archive" => stage_action_envelope("archive"),
      # LIVE (required-positional): a missing positional raises a Thor parse
      # error that routes here.
      "drop" => Envelope.new(schema: "hive-drop", error_kind: "invalid_task_path"),
      "markers" => Envelope.new(schema: "hive-markers-clear", error_kind: "invalid_task_path"),
      # DEAD (defensive): `forget` raises a command-local
      # `UsageError < Hive::Error`; `daemon` raises a command-local
      # `UsageError < Hive::InvalidTaskPath < Hive::Error`; `patrol` accepts
      # a bare invocation and raises only Hive::Error from its body. All
      # three are caught by `bin/hive`'s lower `rescue Hive::Error`, so none
      # of these rows fires today. Kept so a future refactor that routes one
      # through the Thor parse path still emits a contract-valid envelope.
      "forget" => Envelope.new(schema: "hive-forget", error_kind: "missing_name"),
      "daemon" => Envelope.new(schema: "hive-daemon-enroll", error_kind: "missing_project"),
      "patrol" => Envelope.new(schema: "hive-patrol", error_kind: "error"),
      # LIVE (unknown-flag path): these accept a bare invocation so a missing
      # positional never raises, but an *unknown flag* (`hive status --bogus`)
      # still raises a Thor parse error before the body runs and routes here.
      "prune" => Envelope.new(schema: "hive-prune", error_kind: "usage"),
      "status" => Envelope.new(schema: "hive-status", error_kind: "error")
    }.freeze
    # Freezing the hash does not freeze its rows; freeze each Envelope so a
    # post-boot mutation of a row's `schema` can't bypass the load-time
    # guard below.
    ENVELOPES.each_value(&:freeze)

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

    # Parallel load-time guard for the hand-typed `error_kind` literals.
    # Each routed kind must be a member of one of the published closed
    # `*ErrorKind` enums (the union below), so a typo like `invalid_taks_path`
    # fails at boot instead of shipping a contract-violating envelope. The
    # `usage` fallback used by `emit` for unrouted commands is included so
    # the union stays a true superset of every kind this module can emit.
    KNOWN_ERROR_KINDS = [
      Hive::Schemas::RunErrorKind,
      Hive::Schemas::StatusErrorKind,
      Hive::Schemas::StatusDiagnoseErrorKind,
      Hive::Schemas::ForgetErrorKind,
      Hive::Schemas::DropErrorKind,
      Hive::Schemas::EnrollErrorKind,
      Hive::Schemas::PruneErrorKind
    ].flat_map { |mod| mod::ALL }.uniq.freeze

    unknown_kinds = (ENVELOPES.values.map(&:error_kind) + [ "usage" ]) - KNOWN_ERROR_KINDS
    unless unknown_kinds.empty?
      raise "Hive::ThorUsageJson: error_kind(s) not in any closed *ErrorKind enum: #{unknown_kinds.inspect}"
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

      # Compute the payload *before* the write so a fault in `build_payload`
      # (`ErrorEnvelope.build` raising a `KeyError`/`TypeError`, the
      # disjointness guard tripping) lands in the bare rescue below rather
      # than escaping `emit` into `bin/hive` as a raw backtrace.
      payload = build_payload(usage_error, envelope)
      io.puts(JSON.generate(payload))
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
    rescue StandardError => e
      # The JSON path must never be the thing that crashes with a backtrace —
      # that is the exact agent-hostile failure this file exists to prevent.
      # Any other fault building the payload still falls back to the original
      # Thor usage text plus a one-line note on stderr.
      warn_io.puts(error.message)
      warn_io.puts("hive: failed to build JSON error envelope: #{e.class}: #{e.message}")
    end

    # Emit a schema-less generic envelope for an error that escaped the Thor
    # *parse* path entirely — a `Hive::Error` usage error or an unclassified
    # `StandardError` surfaced by `bin/hive`'s top-level rescues when `--json`
    # was requested. Mirrors `build_payload`'s no-schema shape so an agent
    # sees the same fields (including the explicit `null` `schema` sentinel)
    # it gets for an unknown command.
    def emit_generic(error, error_kind:, exit_code:, io: $stdout)
      io.puts(JSON.generate(generic_payload(error, error_kind: error_kind, exit_code: exit_code)))
    rescue Errno::EPIPE
      # Pipe closed downstream — nothing left to report.
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
        # command without a `--json` contract), so we use the
        # semantically-correct `usage` kind rather than the misleading
        # `invalid_task_path`.
        generic_payload(usage_error, error_kind: usage_error.error_kind, exit_code: Hive::ExitCodes::USAGE)
      end
    end

    # Schema-less envelope shared by the unknown-command branch of
    # `build_payload` and `emit_generic`. Keeps the shape consistent with
    # `ErrorEnvelope.build` (same last-`::`-segment `error_class`) and emits
    # an explicit `null` `schema` so an agent dispatching on the `schema`
    # key gets a clean "no routable schema" signal instead of a missing key.
    def generic_payload(error, error_kind:, exit_code:)
      {
        "schema" => nil,
        "ok" => false,
        "error_class" => error.class.name.split("::").last,
        "error_kind" => error_kind,
        "exit_code" => exit_code,
        "message" => error.message
      }
    end
  end
end
