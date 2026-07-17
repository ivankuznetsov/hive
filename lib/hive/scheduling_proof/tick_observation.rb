require "time"

module Hive
  module SchedulingProof
    class TickObservation
      DAEMON_STATES = %w[running stopped].freeze
      TICK_HEALTH = %w[ok degraded].freeze

      def initialize(daemon_instance_id:, daemon_state:, heartbeat_at:, poll_interval_sec:,
                     configuration_fingerprint:, tick_health:, unavailable_live_claims:,
                     configured_slots:, owners:, candidates:)
        @daemon_instance_id = daemon_instance_id.to_s
        @daemon_state = daemon_state.to_s
        @heartbeat_at = coerce_time(heartbeat_at)
        @poll_interval_sec = poll_interval_sec.to_i
        @configuration_fingerprint = configuration_fingerprint.to_s
        @tick_health = tick_health.to_s
        @unavailable_live_claims = Array(unavailable_live_claims).map(&:to_s).uniq.sort
        @configured_slots = configured_slots.to_i
        @owners = stringify(owners)
        @candidates = stringify(candidates)
        validate!
      end

      def to_h
        {
          "schema" => "hive-scheduler-snapshot",
          "schema_version" => 1,
          "daemon_instance_id" => @daemon_instance_id,
          "daemon_state" => @daemon_state,
          "heartbeat_at" => @heartbeat_at.utc.iso8601(6),
          "poll_interval_sec" => @poll_interval_sec,
          "configuration_fingerprint" => @configuration_fingerprint,
          "tick_health" => @tick_health,
          "unavailable_live_claims" => @unavailable_live_claims,
          "tasks" => @candidates.map { |candidate| candidate.reject { |key, _| key == "task_folder" } },
          "fleet" => {
            "configured_slots" => @configured_slots,
            "owners" => @owners,
            "candidates" => @candidates.map { |candidate| candidate.reject { |key, _| key == "task_folder" } }
          }
        }
      end

      private

      def validate!
        raise ArgumentError, "daemon instance identity is required" if @daemon_instance_id.empty?
        raise ArgumentError, "invalid daemon state" unless DAEMON_STATES.include?(@daemon_state)
        raise ArgumentError, "invalid tick health" unless TICK_HEALTH.include?(@tick_health)
        raise ArgumentError, "poll interval must be positive" unless @poll_interval_sec.positive?
        raise ArgumentError, "configured slots must be non-negative" if @configured_slots.negative?
      end

      def stringify(value)
        Array(value).map do |entry|
          entry.to_h.to_h do |key, child|
            [ key.to_s, child.is_a?(Hash) ? child.transform_keys(&:to_s) : child ]
          end
        end
      end

      def coerce_time(value)
        return value if value.is_a?(Time)

        Time.iso8601(value.to_s)
      end
    end
  end
end
