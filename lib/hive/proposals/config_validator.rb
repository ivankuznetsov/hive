require "time"
require "hive/proposals"

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
          label = "proposals.evaluators.#{identity}"
          closed_mapping!(row, EVALUATOR_CONFIG_KEYS, label)
          EVALUATOR_CONFIG_KEYS.each do |key|
            values = row[key]
            unless values.is_a?(Array) && values.length <= 64 && values.uniq == values &&
                   values.all? { |value| bounded_identifier?(value) }
              raise ConfigError, "#{label}.#{key} in #{source} must be a bounded unique array"
            end
          end
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
          label = "proposals.authorities.#{identity}"
          closed_mapping!(row, AUTHORITY_KEYS, label)
          unless AUTHORITY_KINDS.include?(row["kind"])
            raise ConfigError, "#{label}.kind in #{source} must be operator or policy"
          end
          capabilities = row["capabilities"]
          unless capabilities.is_a?(Array) && capabilities.length <= 3 &&
                 capabilities.uniq == capabilities &&
                 capabilities.all? { |capability| AUTHORITY_CAPABILITIES.include?(capability) }
            raise ConfigError, "#{label}.capabilities in #{source} is malformed"
          end
          unless row["version"].is_a?(Integer) && row["version"].positive?
            raise ConfigError, "#{label}.version in #{source} must be positive"
          end
          unless [ true, false ].include?(row["revoked"])
            raise ConfigError, "#{label}.revoked in #{source} must be boolean"
          end
          authority_times!(row, label)
        end
      end

      def authority_times!(row, label)
        times = %w[valid_from valid_until].to_h do |key|
          value = row[key]
          next [ key, nil ] if value.nil?
          parsed = Time.iso8601(value.to_s)
          raise ArgumentError unless value.is_a?(String) && parsed.iso8601 == value
          [ key, parsed ]
        end
        return unless times["valid_from"] && times["valid_until"] &&
                      times["valid_from"] >= times["valid_until"]

        raise ConfigError, "#{label} in #{source} has an empty validity interval"
      rescue ArgumentError
        raise ConfigError, "#{label} validity timestamps in #{source} must be canonical ISO 8601"
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

      def bounded_identifier?(value)
        value.is_a?(String) && !value.empty? && value.bytesize <= 128 &&
          !value.match?(/[\u0000-\u001f\u007f]/)
      end

      def source
        return @source_path if File.exist?(@source_path)
        "#{@source_path} (defaults; no file present)"
      end
    end
  end
end
