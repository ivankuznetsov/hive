require "digest"
require "json"

module Hive
  module WorkLedger
    # Deterministic JSONL decoding and identity checks. A caller-supplied block
    # validates or enriches each decoded record while retaining ownership of
    # schema and migration policy.
    class Replay
      class << self
        def call(bytes:, record_id:, source_label:, record_label:, validator:)
          new(
            bytes: bytes,
            record_id: record_id,
            source_label: source_label,
            record_label: record_label,
            validator: validator
          ).call
        end
      end

      def initialize(bytes:, record_id:, source_label:, record_label:, validator:)
        @bytes = bytes
        @record_id = record_id
        @source_label = source_label.to_s
        @record_label = record_label.to_s
        @validator = validator
      end

      def call
        validate_inputs!
        seen = {}
        last_id = nil
        records = bytes.lines(chomp: true).filter_map.with_index do |line, index|
          next if line.empty?

          record = parse(line, index)
          replacement = validator&.call(record, index + 1)
          record = replacement unless replacement.nil?
          id = record_id.call(record)
          unless id.is_a?(String) && !id.empty?
            raise InvalidRecord,
                  "#{record_label} must be a non-empty string at " \
                  "#{source_label} line #{index + 1}"
          end
          if seen[id]
            raise InvalidRecord,
                  "duplicate #{record_label} #{id.inspect} at #{source_label} line #{index + 1}"
          end
          seen[id] = true
          last_id = id
          record
        end

        ReplayReceipt.new(
          cursor: bytes.bytesize,
          record_id: last_id,
          ledger_hash: ::Digest::SHA256.hexdigest(bytes),
          records: records.freeze
        )
      rescue Error
        raise
      rescue StandardError => e
        raise ReplayFailed, "ledger replay failed: #{e.class}: #{e.message}"
      end

      private

      attr_reader :bytes, :record_id, :source_label, :record_label, :validator

      def validate_inputs!
        raise InvalidRequest, "bytes must be a string" unless bytes.is_a?(String)
        raise InvalidRequest, "record_id must be callable" unless record_id.respond_to?(:call)
        if validator && !validator.respond_to?(:call)
          raise InvalidRequest, "replay validator must be callable"
        end
      end

      def parse(line, index)
        JSON.parse(line)
      rescue JSON::ParserError => e
        raise InvalidRecord,
              "invalid JSON at #{source_label} line #{index + 1}: #{e.message}"
      end
    end
  end
end
