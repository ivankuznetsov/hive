require "hive/provider_health"
require "hive/output_reference"

module Hive
  module ProviderHealth
    class Evidence
      FIELDS = %w[
        failure_class scope provenance route_id reset_hint_seconds fingerprint
        source_reference
      ].freeze

      attr_reader :scope, :failure_class, :provenance, :route, :reset_hint_seconds,
                  :fingerprint, :source_reference, :attempt_id

      def self.from_h(data)
        unless data.is_a?(Hash) && data.keys.sort == FIELDS.sort
          raise InvalidEvidence, "provider evidence has unexpected fields"
        end
        scope = ProviderHealth.scope_from_h(data.fetch("scope"))
        klass = data.fetch("failure_class")
        allowed = scope.provider_account? ? PROVIDER_FAILURE_CLASSES : MODEL_FAILURE_CLASSES
        raise InvalidEvidence, "failure class is not valid for scope" unless allowed.include?(klass)
        provenance = data.fetch("provenance")
        raise InvalidEvidence, "evidence provenance is not allowlisted" unless TRUSTED_PROVENANCE.include?(provenance)
        route_id = ProviderHealth.identifier(data.fetch("route_id"), "route")
        hint = data.fetch("reset_hint_seconds")
        unless hint.nil? || (hint.is_a?(Integer) && hint.between?(0, MAX_RESET_HINT_SECONDS))
          raise InvalidEvidence, "reset hint is outside the allowed bound"
        end
        Hive::OutputReference.validate_shape!(data.fetch("source_reference"))
        expected = ProviderHealth.digest(
          "failure_class" => klass,
          "scope" => scope.to_h,
          "provenance" => provenance,
          "route_id" => route_id,
          "reset_hint_seconds" => hint
        )
        unless expected == data.fetch("fingerprint")
          raise InvalidEvidence, "provider evidence fingerprint does not match safe fields"
        end
        ProviderHealth.deep_freeze(ProviderHealth.deep_copy(data))
      rescue KeyError, InvalidScope, InvalidMutation, Hive::InvalidOutputReference => e
        raise InvalidEvidence, "provider evidence failed validation: #{e.class}"
      end

      def self.from_receipt(data, route:, attempt_id:)
        validated = from_h(data)
        evidence = new(
          scope: ProviderHealth.scope_from_h(validated.fetch("scope")),
          failure_class: validated.fetch("failure_class"),
          provenance: validated.fetch("provenance"),
          route: route,
          reset_hint_seconds: validated.fetch("reset_hint_seconds"),
          source_reference: validated.fetch("source_reference"),
          attempt_id: attempt_id
        )
        unless evidence.to_h == validated
          raise InvalidEvidence, "provider evidence does not match its admitted route"
        end
        evidence
      end

      def initialize(scope:, failure_class:, provenance:, route:, reset_hint_seconds: nil,
                     source_reference:, attempt_id:)
        raise InvalidEvidence, "provider evidence requires an explicit scope" unless scope.is_a?(Scope)
        raise InvalidEvidence, "provider evidence requires a route identity" unless route.is_a?(RouteIdentity)

        klass = failure_class.to_s
        allowed = scope.provider_account? ? PROVIDER_FAILURE_CLASSES : MODEL_FAILURE_CLASSES
        unless allowed.include?(klass)
          raise InvalidEvidence, "failure class is not valid for the explicit evidence scope"
        end
        provenance_value = provenance.to_s
        unless TRUSTED_PROVENANCE.include?(provenance_value)
          raise InvalidEvidence, "provider evidence provenance is not allowlisted"
        end
        unless route.account_id == scope.account_id &&
               (!scope.model? || route.model_id == scope.model_id)
          raise InvalidEvidence, "provider evidence scope does not match its admitted route"
        end
        hint = normalize_hint(reset_hint_seconds)
        reference = normalize_reference(source_reference)

        @scope = scope
        @failure_class = klass.freeze
        @provenance = provenance_value.freeze
        @route = route
        @reset_hint_seconds = hint
        @source_reference = reference
        @attempt_id = ProviderHealth.identifier(attempt_id, "attempt")
        @fingerprint = ProviderHealth.digest(fingerprint_fields).freeze
        freeze
      rescue Hive::InvalidOutputReference => e
        raise InvalidEvidence, e.message
      end

      def to_h
        {
          "failure_class" => failure_class,
          "scope" => scope.to_h,
          "provenance" => provenance,
          "route_id" => route.route_id,
          "reset_hint_seconds" => reset_hint_seconds,
          "fingerprint" => fingerprint,
          "source_reference" => source_reference
        }.freeze
      end

      def idempotency_key(receipt_identity:)
        ProviderHealth.digest(
          "attempt_id" => attempt_id,
          "terminal_receipt" => receipt_identity,
          "route_id" => route.route_id,
          "fingerprint" => fingerprint
        )
      end

      private

      def fingerprint_fields
        {
          "failure_class" => failure_class,
          "scope" => scope.to_h,
          "provenance" => provenance,
          "route_id" => route.route_id,
          "reset_hint_seconds" => reset_hint_seconds
        }
      end

      def normalize_hint(value)
        return nil if value.nil?
        number = Integer(value)
        unless number.between?(0, MAX_RESET_HINT_SECONDS)
          raise InvalidEvidence, "reset hint is outside the allowed bound"
        end
        number
      rescue ArgumentError, TypeError
        raise InvalidEvidence, "reset hint must be an integer number of seconds"
      end

      def normalize_reference(value)
        Hive::OutputReference.validate_shape!(value)
        ProviderHealth.deep_freeze(ProviderHealth.deep_copy(value))
      end
    end
  end
end
