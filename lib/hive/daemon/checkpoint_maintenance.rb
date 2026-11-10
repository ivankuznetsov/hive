require "thread"
require "hive/runtime_control_plane"
require "hive/runtime_control_plane/operation_lock"

module Hive
  module Daemon
    # Daemon-owned, opportunistic WAL maintenance. A pinned reader may defer
    # progress indefinitely; the high water changes cadence, never authority.
    class CheckpointMaintenance
      INTERVAL_SEC = 30.0
      HIGH_WATER_INTERVAL_SEC = 1.0
      HIGH_WATER_BYTES = 16 * 1024 * 1024

      attr_reader :database

      def initialize(path: Hive::Paths.runtime_control_plane_path, logger:,
                     database: nil, high_water_bytes: HIGH_WATER_BYTES,
                     operation_lock_factory: nil,
                     monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @database = database || Hive::RuntimeControlPlane::Database.new(
          path: path, checkpoint_role: :daemon_backed
        )
        @logger = logger
        @high_water_bytes = Integer(high_water_bytes)
        raise ArgumentError, "WAL high water must be positive" unless @high_water_bytes.positive?

        @monotonic = monotonic
        @operation_lock_factory = operation_lock_factory || lambda do
          Hive::RuntimeControlPlane::OperationLock.new(
            state_home: File.dirname(@database.path), timeout_sec: 0
          )
        end
        @owner_pid = Process.pid
        @mutex = Mutex.new
        @last_pass_at = nil
      end

      def sweep
        return unless @owner_pid == Process.pid && @mutex.try_lock

        begin
          now = @monotonic.call
          bytes = database.wal_bytes
          high_water = bytes >= @high_water_bytes
          cadence = high_water ? HIGH_WATER_INTERVAL_SEC : INTERVAL_SEC
          return if @last_pass_at && now - @last_pass_at < cadence

          @last_pass_at = now
          result = @operation_lock_factory.call.synchronize do
            database.passive_checkpoint!(timeout_sec: 0.25)
          end
          report = result.merge(
            checkpoint_role: database.checkpoint_role, cadence_sec: cadence,
            observed_wal_bytes: bytes, high_water_bytes: @high_water_bytes,
            high_water_frames: ((@high_water_bytes - 32).to_f / (result.fetch(:page_size) + 24)).ceil,
            high_water: high_water, deferred: !result.fetch(:complete)
          )
          log(report)
          report
        rescue StandardError => error
          @last_pass_at = now if now
          report = {
            deferred: true, error_class: error.class.name,
            error: error.message.to_s.byteslice(0, 256), observed_wal_bytes: bytes,
            high_water_bytes: @high_water_bytes, cadence_sec: cadence
          }
          log(report)
          report
        ensure
          @mutex.unlock
        end
      end

      def close
        database.disconnect if @owner_pid == Process.pid
      end

      private

      def log(report)
        @logger.event(:runtime_checkpoint_maintenance, **report)
      rescue StandardError
        nil
      end
    end
  end
end
