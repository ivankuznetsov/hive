require "digest"
require "time"
require "hive/runtime_control_plane"

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

      def initialize(store: nil, root: nil, create_directories: true)
        @store = store || Repository.new(root: root, create_directories: create_directories)
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
      rescue RepositoryError
        default_payload.merge(
          "status" => "degraded",
          "hot" => { "records" => nil, "invalid" => nil },
          "last_error" => { "operation" => "status", "class" => "RepositoryError" },
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
        @store.database.transaction do |db|
          row = db[:projections].where(projection_key: projection_key).first
          current = row ? parse(row.fetch(:value_json)) : default_payload
          replacement = yield(current)
          next current if replacement == current

          serialized = RuntimeControlPlane::Codec.dump_json(replacement)
          raise RepositoryError, "attempt storage health is too large" if serialized.bytesize > MAX_BYTES
          values = {
            projection_key: projection_key, source_kind: "attempts",
            source_id: "storage-health", source_generation: 0,
            source_fingerprint: Digest::SHA256.hexdigest(serialized),
            value_json: serialized, created_at: Record.iso8601(Time.now.utc)
          }
          db[:projections].insert_conflict(
            target: :projection_key, update: values.except(:projection_key)
          ).insert(values)
        end
        replacement
      end

      def read
        row = @store.database.read do |db|
          db[:projections].where(projection_key: projection_key).first
        end
        row ? parse(row.fetch(:value_json)) : default_payload
      end

      def parse(bytes)
        data = RuntimeControlPlane::Codec.load_json(bytes)
        valid = data.is_a?(Hash) && data["schema"] == SCHEMA &&
          data["schema_version"] == SCHEMA_VERSION &&
          data["scope"] == "attempt-storage" &&
          data["layout"].is_a?(Hash) && data["maintenance"].is_a?(Hash) &&
          normalize_cold_sweep_cursor(data["cold_sweep_cursor"]) &&
          bytes == RuntimeControlPlane::Codec.dump_json(data)
        raise RepositoryError, "attempt storage health is corrupt" unless valid

        data
      rescue RuntimeControlPlane::Error, EncodingError, ArgumentError, TypeError
        raise RepositoryError, "attempt storage health is corrupt"
      end

      def default_payload
        self.class.unknown_snapshot.except("status", "hot").merge(
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "scope" => "attempt-storage",
          "cold_sweep_cursor" => { "after" => nil }
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
          raise RepositoryError, "attempt storage health counters are invalid"
        end
        normalized
      end

      def optional_count(value)
        return nil if value.nil?
        return value if value.is_a?(Integer) && value >= 0

        raise RepositoryError, "attempt storage health count is invalid"
      end

      def normalize_cold_sweep_cursor(cursor)
        value = cursor.to_h
        after = value["after"]
        valid = value.keys == [ "after" ] &&
          (after.nil? || (after.is_a?(String) && !after.empty? && after.bytesize <= 128))
        raise RepositoryError, "attempt cold sweep cursor is invalid" unless valid

        { "after" => after }
      rescue KeyError, NoMethodError
        raise RepositoryError, "attempt cold sweep cursor is invalid"
      end

      def projection_key = "attempts:storage-health"
    end
  end
end
