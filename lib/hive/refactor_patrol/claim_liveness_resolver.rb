require "hive/process_kill"

module Hive
  module RefactorPatrol
    # Observes whether a fenced claim still owns its recorded process identity.
    # Unlike ProcessGroupResolver, this probe never terminates a live worker.
    class ClaimLivenessResolver
      def call(claim)
        child = !claim["pid"].nil?
        pid = Integer(child ? claim.fetch("pid") : claim.fetch("owner_pid"))
        recorded_start = claim.fetch(
          child ? "process_start_time" : "owner_process_start_time"
        ).to_s
        return :unresolved unless Hive::ProcessKill.valid_target_pid?(pid)
        return :resolved if recorded_start.empty? || !Hive::ProcessKill.pid_alive?(pid)
        return :resolved unless Hive::ProcessKill.process_start_time(pid).to_s == recorded_start
        return :resolved if child && Process.getpgid(pid) != Integer(claim.fetch("pgid"))

        :unresolved
      rescue Errno::ESRCH
        :resolved
      rescue KeyError, ArgumentError, TypeError, Errno::EPERM
        :unresolved
      end
    end
  end
end
