require "hive/errors"
require "hive/schemas"
require "hive/command_error_kind"

module Hive
  # Machine-readable outcome of `hive archive TARGET --reason ... --json`.
  #
  # The CLI has two JSON modes and each one names itself:
  #
  # - `--json` alone is a read-only preview. It keeps the
  #   hive-task-closure-input document and adds `mode: "preview"`,
  #   `applied: false`, and a `next` command that applies the closure.
  # - `--json --yes` applies the closure and reports a
  #   hive-task-closure-result document with `applied: true` and the receipt.
  #
  # Every failure in either mode is one hive-task-closure-result error
  # document. Its `ok: false` is the signal; a retry of the same command is
  # safe because confirmation resumes an existing valid receipt.
  module TaskClosureResult
    SCHEMA = "hive-task-closure-result".freeze
    PREVIEW = "preview".freeze
    APPLY = "apply".freeze
    MODES = [ PREVIEW, APPLY ].freeze

    # Closed `error_kind` vocabulary. The receipt-store kinds come from
    # Hive::CommandErrorKind because keyed closure rides CommandOperation.
    ERROR_KINDS = (%w[
      usage wrong_stage unauthorized verification_failed stale_preview
      invalid_receipt config concurrent_run internal error
    ] + Hive::CommandErrorKind::ALL).freeze

    module_function

    # `next_command` applies this exact closure; nil when the preview is
    # blocked, because nothing can be applied until its errors are fixed.
    def preview(preview_payload, next_command:)
      preview_payload.merge("mode" => PREVIEW, "applied" => false, "next" => next_command)
    end

    def applied(receipt)
      {
        "schema" => SCHEMA,
        "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
        "ok" => true,
        "mode" => APPLY,
        "applied" => true,
        "reason" => receipt.fetch("reason"),
        "task" => receipt.fetch("task"),
        "preview_digest" => receipt.fetch("preview_digest"),
        "receipt_digest" => receipt.fetch("receipt_digest"),
        "receipt" => receipt
      }
    end

    def failed(error, mode:, preview: nil)
      raise ArgumentError, "unknown closure mode: #{mode.inspect}" unless MODES.include?(mode)

      payload = Hive::Schemas::ErrorEnvelope.build(
        schema: SCHEMA, error: error, error_kind: error_kind(error)
      )
      payload["mode"] = mode
      payload["preview"] = preview if preview
      payload
    end

    def error_kind(error)
      typed = Hive::CommandErrorKind.typed(error)
      return typed if typed
      # TaskClosure stays lazy: a usage error can fail the command before it loads.
      return closure_error_kind(error) if defined?(Hive::TaskClosure::Error) && error.is_a?(Hive::TaskClosure::Error)

      case error
      when Hive::WrongStage then "wrong_stage"
      when Hive::UsageError, Hive::InvalidTaskPath then "usage"
      when Hive::ConfigError then "config"
      when Hive::ConcurrentRunError then "concurrent_run"
      when Hive::InternalError then "internal"
      else "error"
      end
    end

    def closure_error_kind(error)
      case error
      when Hive::TaskClosure::InvalidInput then "usage"
      when Hive::TaskClosure::Unauthorized then "unauthorized"
      when Hive::TaskClosure::VerificationFailed then "verification_failed"
      when Hive::TaskClosure::StalePreview then "stale_preview"
      when Hive::TaskClosure::InvalidReceipt then "invalid_receipt"
      else "error"
      end
    end
  end
end
