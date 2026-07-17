require "json"
require "time"

module Hive
  module Daemon
    class InvalidRetryRecord < Hive::Error; end

    # Validated value object for the journal-derived retry projection. It owns
    # no persistence; TaskJournal and TaskProjection remain the durable source
    # of truth.
    class RetryRecord
      SCHEMA = "hive-retry-record".freeze
      SCHEMA_VERSION = 1
      STATES = %w[cooldown ready running succeeded abandoned].freeze
      REQUIRED_KEYS = %w[
        schema schema_version key predecessor_attempt_id current_attempt_id
        retry_count failure_class failure_code evidence guidance
        first_failure_at last_failure_at retry_after state authorization
        operator last_event_id
      ].freeze
      MAX_EVIDENCE_ENTRIES = 32
      MAX_EVIDENCE_BYTES = 16_384

      def initialize(attributes)
        @data = deep_copy(attributes)
        validate!
        deep_freeze(@data)
      end

      def to_h = deep_copy(@data)
      def [](key) = @data[key.to_s]
      def state = @data.fetch("state")
      def retry_count = @data.fetch("retry_count")
      def current_attempt_id = @data["current_attempt_id"]
      def predecessor_attempt_id = @data.fetch("predecessor_attempt_id")
      def failure_code = @data["failure_code"]
      def generation = @data.dig("key", "generation")
      def key = deep_copy(@data.fetch("key"))

      private

      def validate!
        missing = REQUIRED_KEYS - @data.keys
        raise InvalidRetryRecord, "retry record missing #{missing.join(', ')}" unless missing.empty?
        unless @data["schema"] == SCHEMA && @data["schema_version"] == SCHEMA_VERSION
          raise InvalidRetryRecord, "retry record has unsupported schema"
        end

        validate_key!
        unless @data["retry_count"].is_a?(Integer) && @data["retry_count"] >= 0
          raise InvalidRetryRecord, "retry_count must be a non-negative integer"
        end
        unless STATES.include?(@data["state"])
          raise InvalidRetryRecord, "retry state must be one of #{STATES.join(', ')}"
        end
        require_string!("predecessor_attempt_id")
        require_string!("last_event_id")
        if @data["state"] == "running"
          require_string!("current_attempt_id")
        elsif !@data["current_attempt_id"].nil? && !@data["current_attempt_id"].is_a?(String)
          raise InvalidRetryRecord, "current_attempt_id must be a string or null"
        end

        if @data["state"] == "cooldown"
          parse_time!(@data["retry_after"], "retry_after")
        elsif !@data["retry_after"].nil?
          parse_time!(@data["retry_after"], "retry_after")
        end
        %w[first_failure_at last_failure_at].each do |field|
          parse_time!(@data[field], field) unless @data[field].nil?
        end

        evidence = @data["evidence"]
        unless evidence.is_a?(Array) && evidence.length <= MAX_EVIDENCE_ENTRIES
          raise InvalidRetryRecord, "evidence must be a bounded array"
        end
        if JSON.generate(evidence).bytesize > MAX_EVIDENCE_BYTES
          raise InvalidRetryRecord, "evidence exceeds #{MAX_EVIDENCE_BYTES} bytes"
        end
        unless @data["guidance"].nil? || @data["guidance"].is_a?(String)
          raise InvalidRetryRecord, "guidance must be a string or null"
        end
        validate_optional_hash!("authorization")
        validate_optional_hash!("operator")
      rescue JSON::GeneratorError => e
        raise InvalidRetryRecord, "evidence is not JSON-safe: #{e.message}"
      end

      def validate_key!
        value = @data["key"]
        unless value.is_a?(Hash) && %w[project task stage].all? { |field| present_string?(value[field]) } &&
               value["generation"].is_a?(Integer) && value["generation"] >= 0
          raise InvalidRetryRecord, "retry key requires project, task, stage, and non-negative generation"
        end
      end

      def validate_optional_hash!(field)
        value = @data[field]
        return if value.nil? || value.is_a?(Hash)

        raise InvalidRetryRecord, "#{field} must be an object or null"
      end

      def require_string!(field)
        return if present_string?(@data[field])

        raise InvalidRetryRecord, "#{field} must be a non-empty string"
      end

      def present_string?(value)
        value.is_a?(String) && !value.strip.empty?
      end

      def parse_time!(value, field)
        raise InvalidRetryRecord, "#{field} must be an ISO 8601 timestamp" if value.nil?

        Time.iso8601(value)
      rescue ArgumentError, TypeError
        raise InvalidRetryRecord, "#{field} must be an ISO 8601 timestamp"
      end

      def deep_copy(value)
        case value
        when Hash then value.to_h { |key, child| [ key.to_s, deep_copy(child) ] }
        when Array then value.map { |child| deep_copy(child) }
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
