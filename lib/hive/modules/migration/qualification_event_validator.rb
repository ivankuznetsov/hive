require "digest"
require "time"
require "hive/errors"
require "hive/modules/event_ledger"
require "hive/modules/migration/patrol_evidence"
require "hive/modules/migration/qualification_run_descriptor"
require "hive/workflow_package/canonical_json"

module Hive
  module Modules
    module Migration
      # Pure semantic validator for the production schedule event bound into
      # qualification checkpoints and terminal evidence. It performs no
      # filesystem access and returns immutable event and capture projections.
      class QualificationEventValidator
        ERROR = "patrol qualification event is malformed".freeze
        MAX_BYTES = 128 * 1024
        EVENT_KEYS = %w[
          event_id event_name idempotency_key occurred_at payload project
          project_id recorded_at schema schema_version source
        ].freeze
        SOURCE_KEYS = %w[id type].freeze
        EVENT_ID = /\Aevt-[0-9a-f]{64}\z/

        Validation = Data.define(:event, :capture)

        def call(value, module_name:)
          module_name = validated_module(module_name)
          event = PatrolEvidence.immutable_json(
            value,
            label: "patrol qualification event"
          )
          exact!(event, EVENT_KEYS)
          malformed! if canonical(event).bytesize > MAX_BYTES
          malformed! unless
            event["schema"] == Hive::Modules::EventLedger::SCHEMA &&
              event["schema_version"] ==
                Hive::Modules::EventLedger::SCHEMA_VERSION &&
              event["event_name"] == "schedule" &&
              EVENT_ID.match?(event["event_id"].to_s) &&
              nonempty?(event["project_id"]) &&
              nonempty?(event["project"]) &&
              exact_timestamp?(event["occurred_at"]) &&
              exact_timestamp?(event["recorded_at"]) &&
              nonempty?(event["idempotency_key"]) &&
              event["idempotency_key"].bytesize <= 512
          exact!(event["source"], SOURCE_KEYS)
          payload = event["payload"]
          payload_keys = %w[
            due_at legacy_mutator_capture missed_windows schedule
            target_module
          ]
          payload_keys << "target_hook" if
            module_name == "architecture-patrol"
          exact!(payload, payload_keys)
          malformed! unless
            payload["target_module"] == module_name &&
              nonempty?(payload["schedule"]) &&
              exact_timestamp?(payload["due_at"]) &&
              payload["missed_windows"].is_a?(Integer) &&
              payload["missed_windows"] >= 0
          malformed! if
            module_name == "architecture-patrol" &&
              !nonempty?(payload["target_hook"])

          capture = PatrolCapture.from_h(
            payload.fetch("legacy_mutator_capture")
          )
          validate_bindings!(event, capture, module_name)
          Validation.new(event: event, capture: capture).freeze
        rescue Hive::ConfigError => error
          raise error if error.message == ERROR

          malformed!
        rescue ArgumentError, EncodingError, KeyError, NoMethodError,
               TypeError
          malformed!
        end

        private

        def validated_module(value)
          module_name = value.to_s
          malformed! unless
            QualificationRunDescriptor::MODULES.include?(module_name)

          module_name.freeze
        end

        def validate_bindings!(event, capture, module_name)
          source_type = module_name == "patrol" ?
            "legacy_patrol_completion" :
            "legacy_architecture_patrol_completion"
          idempotency_prefix = module_name == "patrol" ?
            "patrol-finalized:" :
            "architecture-patrol-finalized:"
          payload = event.fetch("payload")
          malformed! unless
            capture.module_name == module_name &&
              capture.project.fetch("project_id") ==
                event["project_id"] &&
              capture.project.fetch("name") == event["project"] &&
              event["source"] == {
                "type" => source_type,
                "id" => capture.occurrence_id
              } &&
              event["idempotency_key"] ==
                "#{idempotency_prefix}#{capture.occurrence_id}" &&
              event["occurred_at"] == capture.occurred_at &&
              payload["due_at"] == capture.occurred_at
          expected_id = "evt-#{Digest::SHA256.hexdigest(
            [
              event["project_id"],
              event["event_name"],
              event["idempotency_key"]
            ].join("\0")
          )}"
          malformed! unless event["event_id"] == expected_id
        end

        def exact!(value, keys)
          malformed! unless
            value.is_a?(Hash) &&
              value.keys.all? { |key| key.is_a?(String) } &&
              value.keys.sort == keys.sort
        end

        def nonempty?(value)
          value.is_a?(String) && !value.empty?
        end

        def exact_timestamp?(value)
          return false unless value.is_a?(String)

          value == Time.iso8601(value).utc.iso8601(6)
        rescue ArgumentError
          false
        end

        def canonical(value)
          Hive::WorkflowPackage::CanonicalJSON.generate(value)
        end

        def malformed!
          raise Hive::ConfigError, ERROR
        end
      end
    end
  end
end
