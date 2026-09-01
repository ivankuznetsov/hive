require "json"
require "time"
require "hive/output_reference"
require "hive/patrol_fix"
require "hive/secret_patterns"
require "hive/stringify_keys"

module Hive
  module PatrolFix
    # One bounded, provider-neutral explanation of a failed Patrol attempt.
    # Recovery policy deliberately lives above this value; this class only
    # normalizes trusted process/custody facts and validates the durable bytes.
    module AttemptDiagnostic
      module_function

      SCHEMA = "hive-patrol-fix-attempt-diagnostic".freeze
      SCHEMA_VERSION = 1
      FILENAME = "patrol-fix-attempt-diagnostic.v1.json".freeze
      MAX_BYTES = 16 * 1024
      MAX_DETAIL_BYTES = 2 * 1024
      WORKFLOW = "patrol_fix".freeze
      CODE_PATTERN = /\A[a-z][a-z0-9_]*\z/.freeze
      ANSI_ESCAPE = /\e(?:\[[0-?]*[ -\/]*[@-~]|\][^\a]*(?:\a|\e\\))/.freeze
      OWNER_VALUES = %w[agent provider hive operator unknown].freeze
      REDACTION_VALUES = %w[applied omitted failed].freeze
      TRANSPORT_STATUSES = %w[valid missing oversized malformed duplicate unavailable].freeze
      REQUIRED_FIELDS = %w[
        schema schema_version workflow stage phase task_generation attempt_id
        correlation_id code owner status agent_reason exit_code timed_out cancelled signal
        provider report_status report_parser firewall_status firewall_restoration
        custody_status detail redaction_status secret_policy_version transport_status
        log_reference recorded_at
      ].freeze

      class InvalidDiagnostic < Hive::Error; end

      # Read one terminal diagnostic only through its immutable receipt
      # binding. Callers get no raw-log fallback and no partially trusted
      # document when any identity or custody check fails.
      def read_bound(store:, binding:)
        value = Hive::StringifyKeys.call(binding)
        attempt_id = value.fetch("attempt_id")
        receipt = value.fetch("receipt")
        return nil unless receipt.is_a?(Hash)
        return nil if receipt["exit_status"] == Hive::ExitCodes::TEMPFAIL

        references = Array(receipt["output_references"]).select do |candidate|
          candidate.is_a?(Hash) && File.basename(candidate["path"].to_s) == FILENAME
        end
        return nil unless references.one?

        reference = references.first
        Hive::OutputReference.validate_shape!(reference)

        document = JSON.parse(store.read_output(reference, max_bytes: MAX_BYTES))
        validate!(document)
        return nil unless document["attempt_id"] == attempt_id &&
                          document["correlation_id"] == attempt_id &&
                          document["stage"] == value.fetch("stage").to_s &&
                          document["task_generation"] == value.fetch("task_generation").to_s &&
                          document["log_reference"] == receipt["log_reference"]

        { "document" => document, "reference" => reference }.freeze
      rescue JSON::ParserError, Hive::Error, SystemCallError, IOError,
             KeyError, TypeError
        nil
      end

      def normalize(envelope, stage:, task_generation:, attempt_id:, recorded_at:, redactor: nil,
                    transport_status: "valid", log_reference: nil)
        source = Hive::StringifyKeys.call(envelope)
        detail, redaction_status = safe_detail(source["detail"], redactor: redactor)
        document = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "workflow" => WORKFLOW,
          "stage" => identifier(stage, "stage"),
          "phase" => bounded_token(source["phase"] || "terminal", "phase"),
          "task_generation" => identifier(task_generation, "task generation"),
          "attempt_id" => identifier(attempt_id, "attempt"),
          "correlation_id" => identifier(attempt_id, "correlation"),
          "code" => failure_code(source),
          "owner" => owner_for(source),
          "status" => bounded_token(source["status"] || "error", "status"),
          "agent_reason" => optional_token(source["error_reason"] || source["agent_reason"], "agent reason"),
          "exit_code" => integer_or_nil(source["exit_code"], "exit code"),
          "timed_out" => source["timed_out"] == true,
          "cancelled" => source["cancelled"] == true,
          "signal" => optional_token(source["signal"], "signal"),
          "provider" => provider_projection(source),
          "report_status" => bounded_token(source["report_status"] || "unknown", "report status"),
          "report_parser" => optional_token(source["report_parser"], "report parser"),
          "firewall_status" => bounded_token(source["firewall_status"] || "unknown", "firewall status"),
          "firewall_restoration" => optional_token(source["restore_status"] || source["firewall_restoration"], "firewall restoration"),
          "custody_status" => bounded_token(source["custody_status"] || "unknown", "custody status"),
          "detail" => detail,
          "redaction_status" => redaction_status,
          "secret_policy_version" => Hive::SecretPatterns::POLICY_VERSION,
          "transport_status" => transport_status,
          "log_reference" => log_reference && Hive::StringifyKeys.call(log_reference),
          "recorded_at" => normalize_time(recorded_at)
        }
        validate!(document, require_log_reference: !log_reference.nil?)
        Hive::PatrolFix.deep_freeze(document)
      end

      def finalize(document, log_reference:, expected_attempt_id:, expected_stage:,
                   expected_task_generation:, transport_status: "valid", redactor: nil,
                   provider_signal: nil, provider_name: nil)
        source = Hive::StringifyKeys.call(document)
        validate!(source, require_log_reference: false)
        unless source.fetch("workflow") == WORKFLOW &&
               source.fetch("attempt_id") == expected_attempt_id.to_s &&
               source.fetch("correlation_id") == expected_attempt_id.to_s &&
               source.fetch("stage") == expected_stage.to_s &&
               source.fetch("task_generation") == expected_task_generation.to_s
          raise InvalidDiagnostic, "attempt diagnostic identity does not match its terminal receipt"
        end
        detail, redaction_status = safe_detail(source["detail"], redactor: redactor)
        finalized = source.merge(
          "detail" => detail,
          "redaction_status" => redaction_status == "failed" ? "failed" : source.fetch("redaction_status"),
          "transport_status" => transport_status,
          "log_reference" => Hive::StringifyKeys.call(log_reference)
        )
        finalized = apply_provider_signal(
          finalized, provider_signal: provider_signal, provider_name: provider_name
        )
        validate!(finalized, require_log_reference: true)
        Hive::PatrolFix.deep_freeze(finalized)
      end

      def validate!(document, require_log_reference: true)
        value = Hive::StringifyKeys.call(document)
        unless value.is_a?(Hash) && value.keys.sort == REQUIRED_FIELDS.sort &&
               value["schema"] == SCHEMA && value["schema_version"] == SCHEMA_VERSION
          raise InvalidDiagnostic, "attempt diagnostic has an invalid field set or schema"
        end
        %w[workflow stage phase task_generation attempt_id correlation_id status].each do |key|
          strict_identifier(value[key], key)
        end
        unless value["code"].is_a?(String) && value["code"].bytesize.between?(1, 128) &&
               value["code"].match?(CODE_PATTERN)
          raise InvalidDiagnostic, "attempt diagnostic code is invalid"
        end
        raise InvalidDiagnostic, "attempt diagnostic owner is invalid" unless OWNER_VALUES.include?(value["owner"])
        unless [ true, false ].include?(value["timed_out"]) &&
               [ true, false ].include?(value["cancelled"])
          raise InvalidDiagnostic, "attempt diagnostic process flags are invalid"
        end
        integer_or_nil(value["exit_code"], "exit code")
        strict_optional_token(value["agent_reason"], "agent reason")
        strict_optional_token(value["signal"], "signal")
        validate_provider!(value["provider"])
        %w[report_status firewall_status custody_status].each do |key|
          strict_identifier(value[key], key)
        end
        unless TRANSPORT_STATUSES.include?(value["transport_status"])
          raise InvalidDiagnostic, "attempt diagnostic transport status is invalid"
        end
        strict_optional_token(value["report_parser"], "report parser")
        strict_optional_token(value["firewall_restoration"], "firewall restoration")
        unless value["detail"].nil? ||
               (value["detail"].is_a?(String) && value["detail"].valid_encoding? &&
                value["detail"].bytesize <= MAX_DETAIL_BYTES)
          raise InvalidDiagnostic, "attempt diagnostic detail is invalid"
        end
        unless REDACTION_VALUES.include?(value["redaction_status"]) &&
               value["secret_policy_version"] == Hive::SecretPatterns::POLICY_VERSION
          raise InvalidDiagnostic, "attempt diagnostic secret policy is invalid"
        end
        if require_log_reference
          Hive::OutputReference.validate_shape!(value["log_reference"])
        elsif value["log_reference"]
          Hive::OutputReference.validate_shape!(value["log_reference"])
        end
        Time.iso8601(value.fetch("recorded_at"))
        encoded = JSON.generate(value)
        raise InvalidDiagnostic, "attempt diagnostic exceeds #{MAX_BYTES} bytes" if encoded.bytesize > MAX_BYTES
        if Hive::SecretPatterns.match?(encoded)
          raise InvalidDiagnostic, "attempt diagnostic contains secret-pattern text"
        end
        true
      rescue Hive::InvalidOutputReference, ArgumentError, TypeError, KeyError => e
        raise InvalidDiagnostic, e.message
      end

      def failure_code(source)
        provider_class = provider_failure_class(source)
        return provider_class if provider_class
        return "state_git_index_lock" if source["write_status"] == "lock_conflict"
        return "secret_policy_publish_blocked" if source["publication_status"] == "blocked_by_policy"
        return "validation_mutation" if source["authoritative_state_changed"] == true
        return "fix_worktree_dirty" if source["worktree_status"] == "dirty"
        return "worktree_head_custody_mismatch" if source["head_relation"] == "unexpected_movement"
        if source["protected_git_config_changed"] == true
          return "protected_git_config_tamper"
        end
        return "agent_timeout" if source["timed_out"] == true
        return "agent_cancelled" if source["cancelled"] == true
        return "agent_signalled" unless source["signal"].nil?
        return "agent_exit_nonzero" if source["exit_code"].is_a?(Integer) && source["exit_code"] != 0
        if source["phase"] == "fix_report_admission" || source["report_parser"] == "fix_report"
          return "fix_report_invalid"
        end
        return "agent_report_invalid" if source["report_status"] == "invalid"

        "agent_terminal_failure"
      end
      private_class_method :failure_code

      def owner_for(source)
        code = failure_code(source)
        return "provider" if code.start_with?("provider_") || code.start_with?("model_")
        return "agent" if code.start_with?("agent_")

        "hive"
      end
      private_class_method :owner_for

      def provider_failure_class(source)
        failure = source["provider_failure"]
        value = failure.is_a?(Hash) ? failure["failure_class"] : failure
        value = source.dig("provider_error", "failure_class") if value.to_s.empty?
        value = source.dig("provider_signal", "failure_class") if value.to_s.empty?
        value = provider_kind_code(source.dig("provider_error", "kind")) if value.to_s.empty?
        value = value.to_s
        return nil if value.empty?

        value.start_with?("provider_", "model_") ? value : "provider_#{value}"
      end
      private_class_method :provider_failure_class

      def provider_kind_code(kind)
        case kind.to_s
        when "rate_limited" then "provider_rate_limited"
        when "provider_limit" then "provider_limit"
        when "provider_error" then "provider_error"
        when "model_output_limit" then "model_output_limit"
        else kind
        end
      end
      private_class_method :provider_kind_code

      def provider_projection(source)
        error = source["provider_error"] || {}
        signal = source["provider_signal"] || {}
        name = source["provider"] || error["provider"]
        failure_class = provider_failure_class(source)
        provenance = signal["provenance"] || error["provenance"] ||
          source["provider_provenance"]
        hint = source["retry_at"] || signal["reset_hint_seconds"] ||
          error["reset_hint_seconds"] || error["retry_after"]
        return nil if [ name, failure_class, provenance, hint ].all?(&:nil?)

        {
          "name" => optional_token(name, "provider name"),
          "failure_class" => optional_token(failure_class, "provider failure class"),
          "retry_hint" => hint.nil? ? nil : bounded_utf8(hint, 128),
          "provenance" => optional_token(provenance, "provider provenance")
        }
      end
      private_class_method :provider_projection

      def apply_provider_signal(document, provider_signal:, provider_name:)
        return document unless provider_signal

        signal = Hive::StringifyKeys.call(provider_signal)
        code = provider_failure_class("provider_failure" => signal.fetch("failure_class"))
        document.merge(
          "code" => code,
          "owner" => "provider",
          "provider" => {
            "name" => optional_token(provider_name, "provider name"),
            "failure_class" => optional_token(code, "provider failure class"),
            "retry_hint" => signal["reset_hint_seconds"].nil? ? nil :
              bounded_utf8(signal.fetch("reset_hint_seconds"), 128),
            "provenance" => optional_token(signal.fetch("provenance"), "provider provenance")
          }
        )
      rescue KeyError => e
        raise InvalidDiagnostic, "attempt diagnostic provider signal is invalid: #{e.message}"
      end
      private_class_method :apply_provider_signal

      def validate_provider!(provider)
        return true if provider.nil?
        fields = %w[failure_class name provenance retry_hint]
        unless provider.is_a?(Hash) && provider.keys.sort == fields
          raise InvalidDiagnostic, "attempt diagnostic provider is invalid"
        end
        %w[name failure_class provenance].each do |key|
          strict_optional_token(provider[key], "provider #{key}")
        end
        strict_optional_token(provider["retry_hint"], "provider retry hint")
        true
      end
      private_class_method :validate_provider!

      def safe_detail(value, redactor: nil)
        return [ nil, "omitted" ] if value.nil? || value.to_s.empty?

        callable = redactor || Hive::SecretPatterns.method(:redact)
        text = value.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
        text.gsub!(ANSI_ESCAPE, "")
        redacted = callable.call(text).to_s
        [ bounded_utf8(redacted, MAX_DETAIL_BYTES), "applied" ]
      rescue StandardError
        [ nil, "failed" ]
      end
      private_class_method :safe_detail

      def bounded_utf8(value, max)
        text = value.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
        return text if text.bytesize <= max

        text.byteslice(0, max).to_s.dup.force_encoding(Encoding::UTF_8).scrub("")
      end
      private_class_method :bounded_utf8

      def identifier(value, label)
        text = value.to_s
        unless text.bytesize.between?(1, 128) && text.valid_encoding? &&
               !text.match?(/[\u0000-\u001f\u007f]/)
          raise InvalidDiagnostic, "attempt diagnostic #{label} is invalid"
        end
        text
      end
      private_class_method :identifier

      def bounded_token(value, label)
        identifier(value, label)
      end
      private_class_method :bounded_token

      def optional_token(value, label)
        value.nil? ? nil : bounded_token(value, label)
      end
      private_class_method :optional_token

      def strict_identifier(value, label)
        unless value.is_a?(String)
          raise InvalidDiagnostic, "attempt diagnostic #{label} is invalid"
        end

        identifier(value, label)
      end
      private_class_method :strict_identifier

      def strict_optional_token(value, label)
        value.nil? ? nil : strict_identifier(value, label)
      end
      private_class_method :strict_optional_token

      def integer_or_nil(value, label)
        return nil if value.nil?
        raise InvalidDiagnostic, "attempt diagnostic #{label} is invalid" unless value.is_a?(Integer)

        value
      end
      private_class_method :integer_or_nil

      def normalize_time(value)
        time = value.respond_to?(:utc) ? value.utc : Time.iso8601(value.to_s).utc
        time.iso8601(6)
      rescue ArgumentError
        raise InvalidDiagnostic, "attempt diagnostic recorded_at is invalid"
      end
      private_class_method :normalize_time
    end
  end
end
