require "json"
require "time"
require "hive/attempts/point_storage"

module Hive
  module Attempts
    # One bounded owner-private cell for attempt-layout operations. It records
    # only the latest migration/maintenance outcome; current hot counts come
    # from the reconciliation snapshot and historical stores are never scanned.
    class StorageHealth
      SCHEMA = "hive-attempt-storage-health".freeze
      SCHEMA_VERSION = 1
      KIND = "status".freeze
      KEY = { "scope" => "attempt-storage" }.freeze
      MAX_BYTES = 16 * 1024
      RESULT_KEYS = %w[promoted deleted cold_examined].freeze
      MIGRATION_RESULT_KEYS = %w[source_count promoted hot invalid].freeze
      COLD_SWEEP_SHARDS = 256

      def self.unknown_snapshot
        {
          "status" => "unknown",
          "layout" => {
            "generation" => 4,
            "migration" => "unknown",
            "last_migrated_at" => nil,
            "last_result" => nil
          },
          "hot" => { "records" => nil, "invalid" => nil },
          "maintenance" => {
            "last_started_at" => nil,
            "last_completed_at" => nil,
            "last_result" => nil
          },
          "last_error" => nil,
          "degraded_reason" => nil
        }
      end

      def initialize(root:, create_directories: true)
        @storage = PointStorage.new(
          root: root,
          label: "attempt storage health",
          create_directories: create_directories
        )
      end

      def claim_maintenance(now:, interval_sec:)
        claimed = false
        update do |current|
          started_at = current.dig("maintenance", "last_started_at")
          if started_at && now.utc < Time.iso8601(started_at) + Integer(interval_sec)
            next current
          end

          claimed = true
          current.merge(
            "maintenance" => current.fetch("maintenance").merge(
              "last_started_at" => now.utc.iso8601(6)
            )
          )
        end
        claimed
      end

      def complete_maintenance(now:, result:)
        values = bounded_counts(result, RESULT_KEYS)
        update do |current|
          success = current.merge(
            "maintenance" => current.fetch("maintenance").merge(
              "last_completed_at" => now.utc.iso8601(6),
              "last_result" => values
            )
          )
          clear_matching_failure(success, "maintenance")
        end
      end

      def fail_maintenance(error:, now:)
        record_failure(operation: "maintenance", error: error, now: now)
      end

      def complete_migration(now:, result:)
        values = bounded_counts(result, MIGRATION_RESULT_KEYS)
        update do |current|
          success = current.merge(
            "layout" => {
              "generation" => 4,
              "migration" => "complete",
              "last_migrated_at" => now.utc.iso8601(6),
              "last_result" => values
            }
          )
          clear_matching_failure(success, "migration")
        end
      end

      def fail_migration(error:, now:)
        update do |current|
          failure_payload(current, operation: "migration", error: error, now: now).merge(
            "layout" => current.fetch("layout").merge("migration" => "failed")
          )
        end
      end

      def cold_sweep_cursor
        read.fetch("cold_sweep_cursor").dup.freeze
      end

      def advance_cold_sweep(cursor)
        normalized = normalize_cold_sweep_cursor(cursor)
        update { |current| current.merge("cold_sweep_cursor" => normalized) }
        normalized
      end

      def snapshot(hot_count:, invalid_hot_count:)
        current = read
        current.merge(
          "status" => status_for(current),
          "hot" => {
            "records" => optional_count(hot_count),
            "invalid" => optional_count(invalid_hot_count)
          }
        ).slice(
          "status", "layout", "hot", "maintenance",
          "last_error", "degraded_reason"
        )
      rescue StoreError
        default_payload.merge(
          "status" => "degraded",
          "hot" => { "records" => nil, "invalid" => nil },
          "last_error" => { "operation" => "status", "class" => "StoreError" },
          "degraded_reason" => "health_metadata_unreadable"
        ).slice(
          "status", "layout", "hot", "maintenance",
          "last_error", "degraded_reason"
        )
      end

      private

      def record_failure(operation:, error:, now:)
        update do |current|
          failure_payload(current, operation: operation, error: error, now: now)
        end
      end

      def failure_payload(current, operation:, error:, now:)
        current.merge(
          "last_error" => {
            "operation" => operation,
            "class" => error.class.name.to_s.byteslice(0, 120),
            "observed_at" => now.utc.iso8601(6)
          },
          "degraded_reason" => "#{operation}_failed"
        )
      end

      def clear_matching_failure(payload, operation)
        return payload unless payload.dig("last_error", "operation") == operation

        payload.merge("last_error" => nil, "degraded_reason" => nil)
      end

      def update
        replacement = nil
        @storage.synchronize(KIND, KEY) do
          bytes = @storage.read(KIND, KEY, max_bytes: MAX_BYTES)
          current = bytes ? parse(bytes) : default_payload
          replacement = yield(current)
          next current if replacement == current

          serialized = StorageKey.dump(replacement)
          raise StoreError, "attempt storage health is too large" if serialized.bytesize > MAX_BYTES

          @storage.write(
            KIND, KEY, serialized,
            expected_bytes: bytes, max_existing_bytes: MAX_BYTES
          )
        end
        replacement
      end

      def read
        bytes = @storage.read(KIND, KEY, max_bytes: MAX_BYTES)
        bytes ? parse(bytes) : default_payload
      end

      def parse(bytes)
        data = JSON.parse(bytes)
        valid = data.is_a?(Hash) && data["schema"] == SCHEMA &&
          data["schema_version"] == SCHEMA_VERSION &&
          data["scope"] == "attempt-storage" &&
          data["layout"].is_a?(Hash) && data["maintenance"].is_a?(Hash) &&
          normalize_cold_sweep_cursor(data["cold_sweep_cursor"]) &&
          bytes == StorageKey.dump(data)
        raise StoreError, "attempt storage health is corrupt" unless valid

        data
      rescue JSON::ParserError, EncodingError, ArgumentError, TypeError
        raise StoreError, "attempt storage health is corrupt"
      end

      def default_payload
        self.class.unknown_snapshot.except("status", "hot").merge(
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "scope" => "attempt-storage",
          "cold_sweep_cursor" => { "shard" => 0, "after" => nil }
        )
      end

      def status_for(payload)
        return "degraded" if payload["degraded_reason"]
        return "healthy" if payload.dig("layout", "migration") == "complete"
        return "healthy" if payload.dig("maintenance", "last_completed_at")

        "unknown"
      end

      def bounded_counts(values, allowed)
        normalized = values.to_h.transform_keys(&:to_s).slice(*allowed)
        unless normalized.values.all? { |value| value.is_a?(Integer) && value >= 0 }
          raise StoreError, "attempt storage health counters are invalid"
        end
        normalized
      end

      def optional_count(value)
        return nil if value.nil?
        return value if value.is_a?(Integer) && value >= 0

        raise StoreError, "attempt storage health count is invalid"
      end

      def normalize_cold_sweep_cursor(cursor)
        value = cursor.to_h
        shard = value.fetch("shard")
        after = value["after"]
        valid = value.keys.sort == %w[after shard] &&
          shard.is_a?(Integer) && shard.between?(0, COLD_SWEEP_SHARDS - 1) &&
          (after.nil? || StorageKey.string(after) == after)
        raise StoreError, "attempt cold sweep cursor is invalid" unless valid

        { "shard" => shard, "after" => after }
      rescue KeyError, NoMethodError
        raise StoreError, "attempt cold sweep cursor is invalid"
      end
    end
  end
end
