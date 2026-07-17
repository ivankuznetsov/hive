require "json"
require "hive/atomic_file"
require "hive/paths"

module Hive
  module SchedulingProof
    class SnapshotStore
      SCHEMA = "hive-scheduler-snapshot".freeze
      SCHEMA_VERSION = 1
      ReadResult = Data.define(:snapshot, :status, :error)

      class Error < Hive::Error; end
      class CorruptSnapshot < Error; end
      class NewerSchema < Error; end

      attr_reader :path

      def initialize(path: Hive::Paths.scheduler_snapshot_path)
        @path = File.expand_path(path)
      end

      def read
        return ReadResult.new(snapshot: nil, status: :missing, error: nil) unless File.exist?(path)

        payload = JSON.parse(File.binread(path))
        return ReadResult.new(snapshot: nil, status: :newer_schema, error: "schema version is newer") if newer?(payload)

        validate!(payload)
        ReadResult.new(snapshot: payload, status: :ok, error: nil)
      rescue JSON::ParserError, CorruptSnapshot, SystemCallError => e
        ReadResult.new(snapshot: nil, status: :corrupt, error: "#{e.class}: #{e.message}")
      end

      def write(snapshot)
        existing = read
        raise NewerSchema, existing.error if existing.status == :newer_schema
        raise CorruptSnapshot, existing.error if existing.status == :corrupt

        payload = stringify(snapshot)
        validate!(payload)
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir, mode: 0o700)
        File.chmod(0o700, dir)
        Hive::AtomicFile.write(path, "#{JSON.generate(payload)}\n", mode: 0o600)
        Hive::AtomicFile.fsync_directory(dir)
        path
      rescue NewerSchema, CorruptSnapshot
        raise
      rescue SystemCallError, IOError, JSON::GeneratorError => e
        raise Error, "scheduler snapshot write failed: #{e.class}: #{e.message}"
      end

      private

      def newer?(payload)
        payload.is_a?(Hash) && payload["schema"] == SCHEMA &&
          payload["schema_version"].is_a?(Integer) && payload["schema_version"] > SCHEMA_VERSION
      end

      def validate!(payload)
        unless payload.is_a?(Hash) && payload["schema"] == SCHEMA &&
               payload["schema_version"] == SCHEMA_VERSION
          raise CorruptSnapshot, "unsupported scheduler snapshot schema"
        end
        required = %w[
          daemon_instance_id daemon_state heartbeat_at poll_interval_sec
          configuration_fingerprint tick_health unavailable_live_claims tasks fleet
        ]
        missing = required.reject { |key| payload.key?(key) }
        raise CorruptSnapshot, "scheduler snapshot missing #{missing.join(', ')}" unless missing.empty?
        raise CorruptSnapshot, "scheduler snapshot tasks must be an array" unless payload["tasks"].is_a?(Array)
        raise CorruptSnapshot, "scheduler snapshot fleet must be an object" unless payload["fleet"].is_a?(Hash)

        true
      end

      def stringify(value)
        value.to_h.to_h do |key, child|
          normalized = if child.is_a?(Hash)
            stringify(child)
          elsif child.is_a?(Array)
            child.map { |entry| entry.is_a?(Hash) ? stringify(entry) : entry }
          else
            child
          end
          [ key.to_s, normalized ]
        end
      end
    end
  end
end
