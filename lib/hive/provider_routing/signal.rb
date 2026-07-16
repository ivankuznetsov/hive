require "time"
require "hive/provider_routing"

module Hive
  module ProviderRouting
    Signal = Data.define(
      :provider, :model, :failure_class, :scope, :reset_at,
      :safe_summary, :fingerprint, :evidence_ref
    ) do
      SHARED_CIRCUIT_CLASSES = ProviderRouting::FAILURE_CLASSES.freeze
      NON_CIRCUIT_CLASSES = %w[
        context_length transient timeout network stale_agent unknown
      ].freeze
      KNOWN_CLASSES = (SHARED_CIRCUIT_CLASSES + NON_CIRCUIT_CLASSES).freeze
      SCOPES = %w[provider model task none].freeze

      def initialize(provider:, model:, failure_class:, scope:, reset_at: nil,
                     safe_summary:, fingerprint:, evidence_ref:)
        failure_class = failure_class.to_s
        scope = scope.to_s
        raise ArgumentError, "unknown provider signal class #{failure_class.inspect}" unless KNOWN_CLASSES.include?(failure_class)
        raise ArgumentError, "unknown provider signal scope #{scope.inspect}" unless SCOPES.include?(scope)
        if scope == "model" && model.to_s.strip.empty?
          raise ArgumentError, "model-scoped provider signal requires model"
        end

        super(
          provider: provider.to_s,
          model: model&.to_s,
          failure_class: failure_class,
          scope: scope,
          reset_at: normalize_time(reset_at),
          safe_summary: sanitize(safe_summary, 160),
          fingerprint: sanitize(fingerprint, 128),
          evidence_ref: sanitize(evidence_ref, 240)
        )
      end

      def circuit_worthy?
        SHARED_CIRCUIT_CLASSES.include?(failure_class) && %w[provider model].include?(scope)
      end

      def timed? = ProviderRouting::TIMED_FAILURE_CLASSES.include?(failure_class)
      def administrative? = ProviderRouting::ADMIN_FAILURE_CLASSES.include?(failure_class)

      private

      def normalize_time(value)
        return nil if value.nil?
        return value.utc if value.respond_to?(:utc)

        Time.iso8601(value.to_s).utc
      rescue ArgumentError
        nil
      end

      def sanitize(value, max)
        value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
             .gsub(/[\u0000-\u001f\u007f]/, " ").strip[0, max]
      end
    end
  end
end
