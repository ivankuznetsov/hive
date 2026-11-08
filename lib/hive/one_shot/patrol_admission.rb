require "hive/config"
require "hive/daemon/concurrency_controller"
require "hive/one_shot/schedule_state"

module Hive
  module OneShot
    # Applies the daemon's persisted Patrol controller gate to bounded adapters.
    class PatrolAdmission
      def initialize(entry:, controller: nil)
        @entry = entry
        @controller = controller || build_controller
      end

      def gate(now:)
        @controller.can_dispatch_patrol_scan?(project: project, now: now)
      end

      def apply(items, gate:, now:)
        return items if gate == :ok

        Array(items).map do |item|
          if gate == :project_dropped
            item.merge(
              "bucket" => "waiting_operator", "reason" => gate.to_s,
              "next_check_at" => nil,
              "condition" => { "kind" => "operator_action", "project" => project }
            )
          else
            next item unless item.fetch("bucket") == "runnable_now"

            deadline = now + poll_interval_sec
            item.merge(
              "bucket" => "waiting_external", "reason" => gate.to_s,
              "next_check_at" => deadline,
              "condition" => {
                "kind" => "time_due", "project" => project,
                "deadline" => deadline.utc.iso8601(6)
              }
            )
          end
        end
      end

      private

      def project = @entry.fetch("name")

      def daemon_config
        @daemon_config ||= Hive::Config.load_global_daemon
      end

      def poll_interval_sec = daemon_config.fetch("poll_interval_sec")

      def build_controller
        Hive::Daemon::ConcurrencyController.new(
          max_concurrent_runs: daemon_config.fetch("max_concurrent_runs"),
          max_concurrent_per_project: daemon_config.fetch("max_concurrent_per_project"),
          max_runs_per_day_per_project: daemon_config.fetch("max_runs_per_day_per_project"),
          max_concurrent_patrol_scans: daemon_config.fetch("max_concurrent_patrol_scans"),
          schedule_state_factory: ->(_project) {
            ScheduleState.new(state_root: @entry.fetch("hive_state_path"))
          },
          persistence_scope_projects: [ project ]
        )
      end
    end
  end
end
