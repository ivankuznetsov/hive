require "time"
require "hive/proposals"

module Hive
  module Proposals
    # One validation boundary for evaluator and lifecycle-authority rows.
    # Configuration loading and runtime authorization intentionally consume the
    # same normalized shapes so neither path can silently widen admission.
    module ConfigurationRow
      MAX_EVALUATOR_ENTRIES = 64
      MAX_EVALUATOR_ENTRY_BYTES = 128

      module_function

      def evaluator!(value, label: "proposal evaluator configuration", error: InvalidRecord)
        row = Proposals.stringify(value)
        raise error, "#{label} must be an object" unless row.is_a?(Hash)
        unknown = row.keys - EVALUATOR_CONFIG_KEYS
        unless unknown.empty?
          raise error, "#{label} has unknown fields: #{unknown.sort.join(', ')}"
        end
        EVALUATOR_CONFIG_KEYS.to_h do |key|
          entries = row[key]
          unless entries.is_a?(Array) && entries.uniq == entries &&
                 entries.length <= MAX_EVALUATOR_ENTRIES
            raise error, "#{label} #{key} must be a bounded unique array"
          end
          normalized = entries.map do |entry|
            value = Proposals.label!(entry, label: "#{label} #{key} entry", error:)
            if value.bytesize > MAX_EVALUATOR_ENTRY_BYTES
              raise error, "#{label} #{key} entry exceeds #{MAX_EVALUATOR_ENTRY_BYTES} bytes"
            end
            value
          end
          [ key, normalized.sort ]
        end
      end

      def authority!(value, label: "proposal authority configuration", error: InvalidRecord)
        row = Proposals.closed_hash!(
          value, required: AUTHORITY_REQUIRED_KEYS, optional: AUTHORITY_OPTIONAL_KEYS,
          label:, error:
        )
        unless AUTHORITY_KINDS.include?(row["kind"])
          raise error, "#{label} kind must be operator or policy"
        end
        capabilities = row["capabilities"]
        unless capabilities.is_a?(Array) && capabilities.length <= AUTHORITY_CAPABILITIES.length &&
               capabilities.uniq == capabilities &&
               capabilities.all? { |capability| AUTHORITY_CAPABILITIES.include?(capability) }
          raise error, "#{label} capabilities are malformed"
        end
        unless row["version"].is_a?(Integer) && row["version"].positive?
          raise error, "#{label} version must be positive"
        end
        unless [ true, false ].include?(row["revoked"])
          raise error, "#{label} revoked must be boolean"
        end
        times = AUTHORITY_OPTIONAL_KEYS.to_h do |key|
          [ key, canonical_timestamp(row[key], label:, error:) ]
        end
        if times.values.none?(&:nil?) && Time.iso8601(times.fetch("valid_from")) >=
           Time.iso8601(times.fetch("valid_until"))
          raise error, "#{label} has an empty validity interval"
        end
        {
          "kind" => row.fetch("kind"), "capabilities" => capabilities.sort,
          "version" => row.fetch("version"), "revoked" => row.fetch("revoked"),
          "valid_from" => times["valid_from"], "valid_until" => times["valid_until"]
        }
      end

      def canonical_timestamp(value, label:, error:)
        return if value.nil?

        Proposals.timestamp!(value, label: "#{label} validity timestamp", error:)
      end
      private_class_method :canonical_timestamp
    end
  end
end
