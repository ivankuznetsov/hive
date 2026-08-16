require "bigdecimal"
require "json"
require "time"

module Hive
  module TaskWorkspace
    class SemanticSnapshot
      SCHEMA_VERSION = 2
      RESULT_KINDS = %w[document change].freeze
      USAGE_COVERAGE = %w[complete partial pending unavailable].freeze

      attr_reader :data

      def initialize(generated_at:, task:, status:, headline:, action:, result:,
                     applicability:, usage:, evidence:, diagnostic:, limits: Limits.new)
        @limits = limits
        @data = TaskWorkspace.canonical(
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "generated_at" => normalize_time(generated_at),
          "task" => task.to_h,
          "status" => status.to_h,
          "headline" => headline.to_h,
          "action" => action.to_h,
          "result" => result.to_h,
          "applicability" => applicability.to_h,
          "usage" => decimal_strings(usage.to_h),
          "evidence" => evidence.to_h,
          "diagnostic" => diagnostic.to_h
        )
        validate_contract!
        TaskWorkspace.safe_value!(@data)
        if to_json.bytesize > @limits.fetch(:workspace_bytes)
          raise ArgumentError, "semantic workspace snapshot exceeds workspace_bytes limit"
        end
      end

      def [](key) = data[key.to_s]

      def to_h
        JSON.parse(to_json)
      end

      def to_json(*_args)
        TaskWorkspace.canonical_json(data)
      end

      private

      def validate_contract!
        kind = data.dig("result", "kind").to_s
        raise ArgumentError, "invalid semantic result kind" unless RESULT_KINDS.include?(kind)

        coverage = data.dig("usage", "coverage").to_s
        raise ArgumentError, "invalid semantic usage coverage" unless USAGE_COVERAGE.include?(coverage)

        %w[worktree diff publication media dependencies supporting_artifacts].each do |name|
          unless [ true, false ].include?(data.dig("applicability", name))
            raise ArgumentError, "invalid semantic applicability #{name}"
          end
        end
      end

      def decimal_strings(value)
        case value
        when Hash
          value.to_h { |key, child| [ key, decimal_strings(child) ] }
        when Array
          value.map { |child| decimal_strings(child) }
        when BigDecimal
          value.to_s("F")
        else
          value
        end
      end

      def normalize_time(value)
        Time.iso8601(value.to_s).utc.iso8601(6)
      rescue ArgumentError
        raise ArgumentError, "invalid semantic workspace timestamp"
      end
    end
  end
end
