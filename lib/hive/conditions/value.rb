require "time"
require "hive/conditions/evidence"
require "hive/conditions/registry"

module Hive
  module Conditions
    class InvalidCondition < Hive::Error; end

    module Value
      OBSERVED_STATES = %w[pending satisfied unsatisfied unverifiable].freeze
      PROJECTED_STATES = (OBSERVED_STATES + [ "superseded" ]).freeze

      module_function

      def validate_observation!(record, registry: Registry.default)
        payload = record.fetch("payload", {})
        name = payload["condition"]
        definition = registry.fetch(name)
        state = payload["state"].to_s
        unless OBSERVED_STATES.include?(state)
          raise InvalidCondition, "condition #{name} has invalid observed state #{state.inspect}"
        end
        if record["reason"].to_s.empty?
          raise InvalidCondition, "condition #{name} requires a reason"
        end
        begin
          Time.iso8601(record.fetch("occurred_at"))
        rescue KeyError, ArgumentError, TypeError
          raise InvalidCondition, "condition #{name} requires an ISO 8601 transition time"
        end
        provenance = record["provenance"]
        unless provenance.is_a?(Hash) && !provenance.empty?
          raise InvalidCondition, "condition #{name} requires provenance"
        end
        evidence = record["evidence"]
        unless evidence.is_a?(Array) && !evidence.empty?
          raise InvalidCondition, "condition #{name} requires typed evidence"
        end
        evidence.map { |entry| Evidence.validate!(entry, allowed: definition.allowed_evidence) }
        true
      rescue RegistryError, InvalidEvidence => e
        raise InvalidCondition, e.message
      end
    end
  end
end
