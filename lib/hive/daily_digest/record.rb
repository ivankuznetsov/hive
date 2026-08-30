require "date"
require "digest"
require "json"
require "time"
require "hive/daily_digest"
require "hive/daily_digest/calendar"

module Hive
  module DailyDigest
    # Validation and canonical identity for immutable digest documents. The
    # store accepts plain Hashes at its boundary but persists only this closed
    # shape, so renderers never need to interpret arbitrary source payloads.
    module Record
      SCHEMA = "hive-digest-record".freeze
      SCHEMA_VERSION = 1
      LIFECYCLES = %w[open closed].freeze
      COMPLETENESS = %w[complete partial].freeze
      CONTENT = %w[empty non_empty unknown].freeze
      BOUNDARY_KINDS = %w[calendar_day zone_cutover].freeze
      REQUIRED_KEYS = %w[
        schema schema_version interval_id local_date sequence time_zone starts_at ends_at
        duration_seconds boundary_kind cutover lifecycle closed_at completeness content
        last_materialized_at projects items attention gaps source_frontiers
      ].freeze

      module_function

      def prepare(input)
        data = deep_copy(input)
        unless data.is_a?(Hash)
          raise InvalidRecord, "digest base must be an object"
        end
        missing = REQUIRED_KEYS.reject { |key| data.key?(key) }
        raise InvalidRecord, "digest base is missing #{missing.join(', ')}" unless missing.empty?
        unless data["schema"] == SCHEMA && data["schema_version"] == SCHEMA_VERSION
          raise InvalidRecord, "unsupported digest record schema"
        end

        validate_date!(data.fetch("local_date"))
        Calendar.timezone!(data.fetch("time_zone"))
        starts_at = parse_time!(data.fetch("starts_at"), "starts_at")
        ends_at = parse_time!(data.fetch("ends_at"), "ends_at")
        raise InvalidRecord, "ends_at must be after starts_at" unless ends_at > starts_at
        unless data.fetch("interval_id").to_s.match?(/\A[0-9a-f]{64}\z/)
          raise InvalidRecord, "interval_id must be a SHA-256 digest"
        end
        duration = data.fetch("duration_seconds")
        unless duration.is_a?(Integer) && duration.positive? && duration == (ends_at - starts_at).to_i
          raise InvalidRecord, "duration_seconds must match the persisted interval"
        end
        enum!(data, "lifecycle", LIFECYCLES)
        enum!(data, "completeness", COMPLETENESS)
        enum!(data, "content", CONTENT)
        enum!(data, "boundary_kind", BOUNDARY_KINDS)
        validate_cutover!(data, starts_at)
        if data["lifecycle"] == "closed"
          parse_time!(data.fetch("closed_at"), "closed_at")
        elsif !data["closed_at"].nil?
          raise InvalidRecord, "an open digest cannot have closed_at"
        end
        if data["content"] == "empty" && data["completeness"] != "complete"
          raise InvalidRecord, "empty content requires complete observation"
        end
        parse_time!(data.fetch("last_materialized_at"), "last_materialized_at")
        %w[projects items attention gaps].each do |key|
          raise InvalidRecord, "#{key} must be an array" unless data[key].is_a?(Array)
        end
        unless data["source_frontiers"].is_a?(Hash)
          raise InvalidRecord, "source_frontiers must be an object"
        end
        if !data["sequence"].nil? && (!data["sequence"].is_a?(Integer) || data["sequence"] < 1)
          raise InvalidRecord, "sequence must be null or an integer >= 1"
        end

        data.delete("record_id")
        data["record_id"] = content_id(data, identity_key: "record_id")
        canonical_object(data).freeze
      end

      def prepare_amendment(local_date, input)
        data = deep_copy(input)
        raise InvalidRecord, "digest amendment must be an object" unless data.is_a?(Hash)
        required = %w[amendment_id kind source event_at observed_at amended_at items resolved_gap_ids]
        missing = required.reject { |key| data.key?(key) }
        raise InvalidRecord, "digest amendment is missing #{missing.join(', ')}" unless missing.empty?
        %w[amendment_id kind source].each do |key|
          value = data[key]
          raise InvalidRecord, "#{key} must be a non-empty string" unless value.is_a?(String) && !value.empty?
        end
        data["local_date"] = validate_date!(local_date)
        parse_time!(data["event_at"], "event_at") unless data["event_at"].nil?
        %w[observed_at amended_at].each { |key| parse_time!(data.fetch(key), key) }
        %w[items resolved_gap_ids].each do |key|
          raise InvalidRecord, "#{key} must be an array" unless data[key].is_a?(Array)
        end
        data["gaps"] ||= []
        data["attention"] ||= []
        data["resolved_gaps"] ||= []
        data["source_frontiers"] ||= {}
        raise InvalidRecord, "gaps must be an array" unless data["gaps"].is_a?(Array)
        raise InvalidRecord, "attention must be an array" unless data["attention"].is_a?(Array)
        unless data["resolved_gaps"].is_a?(Array)
          raise InvalidRecord, "resolved_gaps must be an array"
        end
        resolved_ids = data["resolved_gaps"].map { |gap| gap.fetch("gap_id") }.sort
        unless (resolved_ids - data["resolved_gap_ids"].map(&:to_s)).empty?
          raise InvalidRecord, "resolved_gaps must match resolved_gap_ids"
        end
        unless data["source_frontiers"].is_a?(Hash)
          raise InvalidRecord, "source_frontiers must be an object"
        end
        canonical_object(data).freeze
      end

      def canonical_json(value)
        JSON.generate(canonical_object(value))
      end

      def content_id(value, identity_key: nil)
        payload = deep_copy(value)
        payload.delete(identity_key) if identity_key && payload.is_a?(Hash)
        Digest::SHA256.hexdigest(canonical_json(payload))
      end

      def canonical_object(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.each_with_object({}) do |key, out|
            source_key = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
            out[key] = canonical_object(value.fetch(source_key))
          end
        when Array then value.map { |entry| canonical_object(entry) }
        when String then value.dup
        else value
        end
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      rescue JSON::GeneratorError, TypeError => error
        raise InvalidRecord, "digest value is not JSON-safe: #{error.message}"
      end
      private_class_method :deep_copy

      def validate_date!(value)
        Date.iso8601(value.to_s).iso8601
      rescue Date::Error, TypeError
        raise InvalidRecord, "invalid digest local_date #{value.inspect}"
      end
      private_class_method :validate_date!

      def parse_time!(value, key)
        Time.iso8601(value.to_s)
      rescue ArgumentError, TypeError
        raise InvalidRecord, "#{key} must be an ISO-8601 timestamp"
      end
      private_class_method :parse_time!

      def enum!(data, key, values)
        return if values.include?(data[key])

        raise InvalidRecord, "#{key} must be one of #{values.join(', ')}"
      end
      private_class_method :enum!

      def validate_cutover!(data, starts_at)
        cutover = data.fetch("cutover")
        if data.fetch("boundary_kind") == "calendar_day"
          raise InvalidRecord, "calendar-day intervals cannot carry cutover metadata" unless cutover.nil?

          return
        end
        unless cutover.is_a?(Hash)
          raise InvalidRecord, "zone-cutover intervals require cutover metadata"
        end
        required = %w[requested_at effective_at previous_time_zone skipped_labels]
        missing = required.reject { |key| cutover.key?(key) }
        raise InvalidRecord, "cutover is missing #{missing.join(', ')}" unless missing.empty?

        parse_time!(cutover.fetch("requested_at"), "cutover.requested_at")
        effective_at = parse_time!(cutover.fetch("effective_at"), "cutover.effective_at")
        unless effective_at == starts_at
          raise InvalidRecord, "cutover.effective_at must equal starts_at"
        end
        if cutover.fetch("previous_time_zone").to_s.empty?
          raise InvalidRecord, "cutover.previous_time_zone must be non-empty"
        end
        Calendar.timezone!(cutover.fetch("previous_time_zone"))
        unless cutover.fetch("skipped_labels").is_a?(Array)
          raise InvalidRecord, "cutover.skipped_labels must be an array"
        end
        cutover.fetch("skipped_labels").each { |label| validate_date!(label) }
      rescue KeyError
        raise InvalidRecord, "cutover metadata is incomplete"
      end
      private_class_method :validate_cutover!
    end
  end
end
