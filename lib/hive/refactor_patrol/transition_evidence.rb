require "digest"
require "hive/workflow_package/canonical_json"

module Hive
  module RefactorPatrol
    # Canonical integrity evidence and reconciliation projection for one exact
    # occurrence-journal effect. The digest intentionally covers the persisted
    # effect semantic, not a caller payload the journal does not retain.
    module TransitionEvidence
      SEMANTIC_KEYS = %w[
        idempotency_key intent_id module occurrence_id owner_epoch scope sink
        target
      ].freeze

      module_function

      def semantic(intent)
        {
          "intent_id" => intent.intent_id,
          "module" => intent.module_name,
          "occurrence_id" => intent.occurrence_id,
          "owner_epoch" => intent.owner_epoch,
          "sink" => intent.sink,
          "target" => intent.target,
          "idempotency_key" => intent.idempotency_key,
          "scope" => intent.scope
        }
      end

      def semantic_digest(value)
        semantic = value.respond_to?(:intent_id) ? self.semantic(value) : value
        unless semantic.is_a?(Hash) &&
               semantic.keys.sort == SEMANTIC_KEYS
          raise ArgumentError, "transition effect semantic is malformed"
        end

        Digest::SHA256.hexdigest(
          Hive::WorkflowPackage::CanonicalJSON.generate(semantic)
        )
      end

      def record(intent, operation:, error_code: nil)
        {
          "intent_id" => intent.intent_id,
          "operation" => operation,
          "semantic_digest" => semantic_digest(intent),
          "error_code" => error_code
        }
      end

      def matched_result(entry)
        outcome = {
          "transition_status" => entry.fetch("outcome")
        }
        if entry.fetch("outcome") == "rejected"
          outcome["error_code"] = entry.fetch("error_code")
        end
        { "status" => "matched", "outcome" => outcome }
      end
    end
  end
end
