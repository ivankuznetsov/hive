require "hive/attempts/repository"
require "hive/lock"
require "hive/paths"
require "hive/pid_file"

module Hive
  module OneShot
    # One project-wide stop-safety probe shared by every bounded scheduler pass.
    # Durable attempts and compatibility task leases are independent worker
    # authorities, so both must be empty before a report can authorize stopping.
    class ProjectLiveness
      MAX_LEASES = 10_000

      def initialize(entry:, state_home: Hive::Paths.state_home, attempt_store: nil,
                     lease_repository: nil)
        @entry = entry
        @state_home = state_home
        @attempt_store = attempt_store
        @lease_repository = lease_repository
      end

      def safe_to_stop?
        !durable_attempt_live? && !task_lease_worker_live?
      end

      private

      def durable_attempt_live?
        attempt_store.active_attempts.any? do |attempt|
          attempt["project"].to_s == @entry.fetch("name").to_s && attempt.live?
        end
      end

      def task_lease_worker_live?
        leases = lease_repository.active_leases(
          state_roots: [ @entry.fetch("hive_state_path") ], limit: MAX_LEASES + 1
        )
        return true if leases.length > MAX_LEASES

        leases.any? do |lease|
          next true if lease.fetch(:malformed)

          payload = lease.fetch(:payload)
          identity_alive?(payload["pid"], payload["process_start_time"]) ||
            identity_alive?(payload["claude_pid"], payload["claude_pid_start_time"])
        end
      end

      def identity_alive?(pid, process_start_time)
        Hive::PidFile.identity_alive?(
          pid, recorded_start_time: process_start_time, require_start_time: true
        )
      end

      def attempt_store
        @attempt_store ||= Hive::Attempts::Repository.open_default(state_home: @state_home)
      end

      def lease_repository
        @lease_repository ||= Hive::Lock.task_lease_repository
      end
    end
  end
end
