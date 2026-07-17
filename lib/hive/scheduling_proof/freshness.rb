require "time"

module Hive
  module SchedulingProof
    module Freshness
      LIVE_CLAIMS = %w[queue_position capacity provider_route scheduler_decision].freeze
      MIN_STALE_SEC = 90

      module_function

      def project(as_of:, heartbeat_at:, poll_interval_sec:, daemon_running:,
                  unavailable_live_claims: [])
        now = coerce_time(as_of)
        heartbeat = coerce_time(heartbeat_at) unless heartbeat_at.nil? || heartbeat_at.to_s.empty?
        threshold = [ poll_interval_sec.to_i * 2, MIN_STALE_SEC ].max
        age = heartbeat && [ now - heartbeat, 0 ].max.round
        stale = !daemon_running || heartbeat.nil? || age > threshold
        daemon_state = if !daemon_running
          "stopped"
        elsif heartbeat.nil?
          "unavailable"
        elsif stale
          "stale"
        else
          "running"
        end
        unavailable = Array(unavailable_live_claims).map(&:to_s)
        unavailable |= LIVE_CLAIMS if stale

        {
          "as_of" => now.utc.iso8601(6),
          "scheduler_heartbeat_at" => heartbeat&.utc&.iso8601(6),
          "snapshot_age_sec" => age,
          "stale_after_sec" => threshold,
          "stale" => stale,
          "daemon_state" => daemon_state,
          "unavailable_live_claims" => unavailable.sort
        }
      end

      def coerce_time(value)
        return value if value.is_a?(Time)
        return Time.iso8601(value) unless value.nil? || value.to_s.empty?

        Time.at(0).utc
      rescue ArgumentError, TypeError
        Time.at(0).utc
      end
    end
  end
end
