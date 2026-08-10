require "json"
require "hive/attempts/point_storage"
require "hive/attempts/record"

module Hive
  module Attempts
    # Immutable, record-compatible schema-v3 proof. It is deliberately
    # point-addressed and exposes no enumeration API.
    class PermanentProofStore
      MAX_RECORD_BYTES = 4 * 1024 * 1024
      KIND = "attempt".freeze

      attr_reader :root

      def initialize(root:, create_directories: true)
        @storage = PointStorage.new(
          root: root,
          label: "attempt permanent proof",
          create_directories: create_directories
        )
        @root = @storage.root
      end

      def fetch(attempt_id)
        id = attempt_id_key(attempt_id)
        bytes = @storage.read(KIND, key(id), max_bytes: MAX_RECORD_BYTES)
        bytes && parse(bytes, expected_attempt_id: id)
      end

      def publish(record)
        unless record.is_a?(Record) && record.final?
          raise StoreError, "permanent attempt proof requires a final schema-v3 record"
        end

        id = attempt_id_key(record.attempt_id)
        bytes = JSON.generate(record.to_h) + "\n"
        raise StoreError, "permanent attempt proof is too large" if bytes.bytesize > MAX_RECORD_BYTES

        @storage.synchronize(KIND, key(id)) do
          current = @storage.read(KIND, key(id), max_bytes: MAX_RECORD_BYTES)
          if current
            existing = parse(current, expected_attempt_id: id)
            unless existing.to_h == record.to_h
              raise StoreError, "permanent attempt proof conflicts with immutable proof"
            end
            next existing
          end

          @storage.write(
            KIND,
            key(id),
            bytes,
            expected_bytes: nil,
            max_existing_bytes: MAX_RECORD_BYTES
          )
          record
        end
      end

      def path_for(attempt_id)
        @storage.path_for(KIND, key(attempt_id_key(attempt_id)))
      end

      private

      def key(attempt_id) = { "attempt_id" => attempt_id }

      def attempt_id_key(value)
        StorageKey.string(value)
      end

      def parse(bytes, expected_attempt_id:)
        raise StoreError, "permanent attempt proof is too large" if bytes.bytesize > MAX_RECORD_BYTES

        record = Record.new(JSON.parse(bytes))
        unless record.attempt_id == expected_attempt_id
          raise StoreError, "permanent attempt proof key collision"
        end
        unless record.final?
          raise StoreError, "permanent attempt proof is not final"
        end

        record
      rescue JSON::ParserError, InvalidRecord => error
        raise StoreError, "permanent attempt proof is unreadable: #{error.message}"
      end
    end
  end
end
