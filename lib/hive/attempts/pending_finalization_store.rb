require "json"
require "hive/attempts/point_storage"

module Hive
  module Attempts
    # Durable per-attempt finalization obligations. Entries are point-addressed
    # and intentionally have no enumeration API, so they never become attempt
    # history or part of Store#scan.
    class PendingFinalizationStore
      SCHEMA = "hive-attempt-pending-finalization".freeze
      SCHEMA_VERSION = 1
      KIND = "attempt".freeze
      MAX_ENTRY_BYTES = 64 * 1024
      MAX_CONSUMERS = 32
      ENTRY_KEYS = %w[attempt_id consumers schema schema_version].freeze

      attr_reader :root

      def initialize(root:, create_directories: true)
        @storage = PointStorage.new(
          root: root,
          label: "attempt pending finalization",
          create_directories: create_directories
        )
        @root = @storage.root
      end

      def create(attempt_id:, consumers:)
        id = StorageKey.string(attempt_id)
        names = Array(consumers).map { |consumer| consumer_name(consumer) }.uniq.sort
        if names.empty? || names.size > MAX_CONSUMERS
          raise StoreError, "pending finalization consumers are invalid"
        end
        candidate = payload(id, names.to_h { |consumer| [ consumer, false ] })

        update(id) do |current|
          if current && current != candidate
            raise StoreError, "pending finalization conflicts with existing obligations"
          end
          candidate
        end
      end

      def fetch(attempt_id)
        id = StorageKey.string(attempt_id)
        bytes = @storage.read(KIND, key(id), max_bytes: MAX_ENTRY_BYTES)
        bytes && parse(bytes, expected_attempt_id: id)
      end

      def acknowledge(attempt_id, consumer:)
        id = StorageKey.string(attempt_id)
        name = consumer_name(consumer)
        update(id) do |current|
          raise StoreError, "pending finalization is missing" unless current
          unless current.fetch("consumers").key?(name)
            raise StoreError, "pending finalization consumer is unknown"
          end

          next current if current.fetch("consumers").fetch(name)

          current.merge(
            "consumers" => current.fetch("consumers").merge(name => true)
          )
        end
      end

      def complete?(attempt_id)
        entry = fetch(attempt_id)
        entry && entry.fetch("consumers").values.all?(true) || false
      end

      def path_for(attempt_id)
        @storage.path_for(KIND, key(StorageKey.string(attempt_id)))
      end

      private

      def update(attempt_id)
        point_key = key(attempt_id)
        @storage.synchronize(KIND, point_key) do
          bytes = @storage.read(KIND, point_key, max_bytes: MAX_ENTRY_BYTES)
          current = bytes && parse(bytes, expected_attempt_id: attempt_id)
          replacement = yield(current)
          next current if current == replacement

          serialized = StorageKey.dump(replacement)
          raise StoreError, "pending finalization entry is too large" if serialized.bytesize > MAX_ENTRY_BYTES

          @storage.write(
            KIND,
            point_key,
            serialized,
            expected_bytes: bytes,
            max_existing_bytes: MAX_ENTRY_BYTES
          )
          replacement
        end
      end

      def parse(bytes, expected_attempt_id:)
        data = JSON.parse(bytes)
        consumers = data["consumers"] if data.is_a?(Hash)
        valid = data.is_a?(Hash) &&
          data.keys.sort == ENTRY_KEYS.sort &&
          data["schema"] == SCHEMA &&
          data["schema_version"] == SCHEMA_VERSION &&
          data["attempt_id"] == expected_attempt_id &&
          consumers.is_a?(Hash) &&
          !consumers.empty? &&
          consumers.size <= MAX_CONSUMERS &&
          consumers.keys.all? { |consumer| consumer_name(consumer) == consumer } &&
          consumers.values.all? { |acknowledged| acknowledged == true || acknowledged == false } &&
          bytes == StorageKey.dump(data)
        raise StoreError, "pending finalization entry is corrupt or colliding" unless valid

        data
      rescue JSON::ParserError, EncodingError, ArgumentError, TypeError
        raise StoreError, "pending finalization entry is corrupt or colliding"
      end

      def payload(attempt_id, consumers)
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "attempt_id" => attempt_id,
          "consumers" => consumers
        }
      end

      def key(attempt_id) = { "attempt_id" => attempt_id }

      def consumer_name(value)
        name = StorageKey.string(value)
        return name if /\A[a-z][a-z0-9_-]{0,63}\z/.match?(name)

        raise StoreError, "pending finalization consumer is invalid"
      end
    end
  end
end
