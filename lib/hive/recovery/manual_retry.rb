require "hive/daemon/recovery_coordinator"

module Hive
  module Recovery
    # Attached recovery consumes the same guarded v5 transition as the daemon.
    # Admission and marker repair remain coordinator responsibilities.
    class ManualRetry
      def initialize(coordinator:, state_home: Hive::Paths.state_home)
        @coordinator = coordinator
        @state_home = state_home
      end

      def call(row:, observation_token:, now: Time.now.utc)
        @coordinator.prepare_manual(row: row, observation_token: observation_token, now: now)
      end
    end
  end
end
