require "time"
require "hive/proposals"
require "hive/proposals/configuration_row"

module Hive
  module Proposals
    class ConfigValidator
      KEYS = %w[evaluators authorities evidence limits context].freeze
      AUTHORITY_KEYS = (AUTHORITY_REQUIRED_KEYS + AUTHORITY_OPTIONAL_KEYS).freeze
      EVIDENCE_KEYS = %w[visibility retention allowed_link_schemes].freeze
      LIMIT_KEYS = %w[
        max_pending_sources max_project_events max_proposal_events max_project_bytes
        max_proposal_bytes max_sources_per_actor_per_hour
      ].freeze
      CONTEXT_KEYS = %w[max_items max_bytes].freeze
      IDENTIFIER = /\A[a-z][a-z0-9_.-]{0,127}\z/

      def self.validate!(proposals, source_path:)
        new(proposals, source_path).validate!
      end

      def initialize(proposals, source_path)
        @proposals = proposals
        @source_path = source_path
      end

      def validate!
        closed_mapping!(@proposals, KEYS, "proposals")
        evaluators!(@proposals.fetch("evaluators"))
        authorities!(@proposals.fetch("authorities"))
        evidence!(@proposals.fetch("evidence"))
        limits!(@proposals.fetch("limits"))
        context!(@proposals.fetch("context"))
      end

      private

      def evaluators!(evaluators)
        unless evaluators.is_a?(Hash) && evaluators.length <= 256
          raise ConfigError, "proposals.evaluators in #{source} must be a bounded Hash"
        end
        evaluators.each do |identity, row|
          unless identity.to_s.match?(IDENTIFIER) && row.is_a?(Hash)
            raise ConfigError, "proposals.evaluators identity in #{source} is malformed"
          end
          ConfigurationRow.evaluator!(
            row, label: "proposals.evaluators.#{identity} in #{source}", error: ConfigError
          )
        end
      end

      def authorities!(authorities)
        unless authorities.is_a?(Hash) && authorities.length <= 256
          raise ConfigError, "proposals.authorities in #{source} must be a bounded Hash"
        end
        authorities.each do |identity, row|
          unless identity.to_s.match?(IDENTIFIER) && row.is_a?(Hash)
            raise ConfigError, "proposals.authorities identity in #{source} is malformed"
          end
          ConfigurationRow.authority!(
            row, label: "proposals.authorities.#{identity} in #{source}", error: ConfigError
          )
        end
      end

      def evidence!(evidence)
        raise ConfigError, "proposals.evidence in #{source} must be a Hash" unless evidence.is_a?(Hash)
        closed_mapping!(evidence, EVIDENCE_KEYS, "proposals.evidence")
        unless VISIBILITIES.include?(evidence["visibility"])
          raise ConfigError,
                "proposals.evidence.visibility in #{source} must be restricted, private, or project"
        end
        unless RETENTIONS.include?(evidence["retention"])
          raise ConfigError, "proposals.evidence.retention in #{source} is invalid"
        end
        schemes = evidence["allowed_link_schemes"]
        unless schemes.is_a?(Array) && schemes.length <= 16 && schemes.uniq == schemes &&
               schemes.all? { |scheme| scheme.to_s.match?(/\A[a-z][a-z0-9+.-]*\z/) }
          raise ConfigError,
                "proposals.evidence.allowed_link_schemes in #{source} is malformed"
        end
      end

      def limits!(limits)
        raise ConfigError, "proposals.limits in #{source} must be a Hash" unless limits.is_a?(Hash)
        closed_mapping!(limits, LIMIT_KEYS, "proposals.limits")
        LIMIT_KEYS.each do |key|
          value = limits[key]
          unless value.is_a?(Integer) && value.positive?
            raise ConfigError, "proposals.limits.#{key} in #{source} must be a positive integer"
          end
        end
        if limits["max_proposal_events"] > limits["max_project_events"] ||
           limits["max_proposal_bytes"] > limits["max_project_bytes"]
          raise ConfigError, "proposal-level limits in #{source} cannot exceed project limits"
        end
      end

      def context!(context)
        raise ConfigError, "proposals.context in #{source} must be a Hash" unless context.is_a?(Hash)
        closed_mapping!(context, CONTEXT_KEYS, "proposals.context")
        CONTEXT_KEYS.each do |key|
          value = context[key]
          unless value.is_a?(Integer) && value.positive?
            raise ConfigError, "proposals.context.#{key} in #{source} must be a positive integer"
          end
        end
      end

      def closed_mapping!(value, allowed, label)
        unknown = value.keys.map(&:to_s) - allowed
        return if unknown.empty?
        raise ConfigError, "#{label} in #{source} has unknown field(s): #{unknown.sort.join(', ')}"
      end

      def source
        return @source_path if File.exist?(@source_path)
        "#{@source_path} (defaults; no file present)"
      end
    end
  end
end
