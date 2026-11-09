module Hive
  module Attempts
    # Resolves daemon-owned launch controls for one exact admitted argv. The
    # caller supplies the freshly loaded global daemon block so long-lived
    # daemons do not retain boot-time capacity or timeout settings.
    module LaunchPolicy
      module_function

      def timeout_sec(daemon:, argv:)
        timeout = daemon.fetch("child_verb_timeouts", {}).fetch(
          verb_for(argv), daemon.fetch("child_timeout_sec")
        ).to_i
        timeout if timeout.positive?
      end

      def kill_grace_sec(daemon:)
        daemon.fetch("child_kill_grace_sec").to_i
      end

      # Host-level memory cap for the attempt's systemd user scope. Older
      # global configs may predate the keys, so fall back to "disabled".
      def memory_limits(daemon:)
        {
          memory_max: daemon.fetch("attempt_memory_max", false),
          memory_swap_max: daemon.fetch("attempt_memory_swap_max", false)
        }
      end

      def limits(daemon:)
        {
          max_global: daemon.fetch("max_concurrent_runs"),
          max_per_project: daemon.fetch("max_concurrent_per_project"),
          max_daily: daemon.fetch("max_runs_per_day_per_project")
        }
      end

      def verb_for(argv)
        Array(argv)[1].to_s
      end
      private_class_method :verb_for
    end
  end
end
