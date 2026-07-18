module Hive
  module Conditions
    class InvalidEvidence < Hive::Error; end

    module Evidence
      REQUIRED_FIELDS = {
        journal_event: %w[event_id],
        attempt_lease: %w[attempt_id lease_version state],
        commit: %w[sha branch],
        file: %w[path digest],
        pull_request: %w[url number observed_head_sha state]
      }.freeze

      module_function

      def validate!(value, allowed: nil)
        evidence = stringify(value)
        raise InvalidEvidence, "condition evidence must be an object" unless evidence.is_a?(Hash)

        type_name = evidence["type"].to_s
        type = type_name.to_sym
        fields = REQUIRED_FIELDS[type]
        raise InvalidEvidence, "unknown evidence type #{type_name.inspect}" unless fields
        if allowed && !Array(allowed).map(&:to_sym).include?(type)
          raise InvalidEvidence, "evidence type #{type} is not allowed for this condition"
        end

        missing = fields.select { |field| missing_value?(evidence[field]) }
        raise InvalidEvidence, "#{type} evidence missing #{missing.join(', ')}" unless missing.empty?

        validate_types!(type, evidence)
        deep_freeze(evidence)
      end

      def validate_types!(type, evidence)
        if type == :attempt_lease && (!evidence["lease_version"].is_a?(Integer) || evidence["lease_version"].negative?)
          raise InvalidEvidence, "attempt_lease evidence lease_version must be non-negative"
        end
        if type == :pull_request && (!evidence["number"].is_a?(Integer) || evidence["number"] <= 0)
          raise InvalidEvidence, "pull_request evidence number must be positive"
        end
        if type == :file && !evidence["digest"].to_s.match?(/\A[0-9a-f]{64}\z/)
          raise InvalidEvidence, "file evidence digest must be a SHA-256 hex value"
        end
        return unless %i[commit pull_request].include?(type)

        field = type == :commit ? "sha" : "observed_head_sha"
        return if evidence[field].to_s.match?(/\A[0-9a-f]{7,64}\z/)

        raise InvalidEvidence, "#{type} evidence #{field} must be a commit SHA"
      end

      def missing_value?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end

      def stringify(value)
        case value
        when Hash then value.to_h { |key, child| [ key.to_s, stringify(child) ] }
        when Array then value.map { |child| stringify(child) }
        else value
        end
      end

      def deep_freeze(value)
        case value
        when Hash then value.each_value { |child| deep_freeze(child) }
        when Array then value.each { |child| deep_freeze(child) }
        end
        value.freeze
      end
    end
  end
end
