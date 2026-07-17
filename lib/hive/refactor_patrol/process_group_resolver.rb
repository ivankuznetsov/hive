require "hive/process_kill"

module Hive
  module RefactorPatrol
    # Resolves an expired fenced claim only after proving its recorded owner or
    # child process is gone. A live PID must also retain the recorded process
    # start time, preventing PID reuse from authorizing a stale takeover.
    class ProcessGroupResolver
      def call(claim)
        return resolve_owner(claim) if claim["pid"].nil?

        pid = Integer(claim.fetch("pid"))
        pgid = Integer(claim.fetch("pgid"))
        recorded_start = claim.fetch("process_start_time").to_s
        return :unresolved unless Hive::ProcessKill.valid_target_pid?(pid)
        return :resolved unless Hive::ProcessKill.pid_alive?(pid)
        return :unresolved if pgid <= 1 || recorded_start.empty?

        live_start = Hive::ProcessKill.process_start_time(pid)
        return :unresolved if live_start.to_s.empty?
        return :resolved unless live_start.to_s == recorded_start
        return :unresolved unless Process.getpgid(pid) == pgid

        result = Hive::ProcessKill.terminate_process_group(
          pid, recorded_start_time: recorded_start
        )
        result.killed || result.skipped_reason == "not_alive" ? :resolved : :unresolved
      rescue KeyError, ArgumentError, TypeError, Errno::EPERM
        :unresolved
      rescue Errno::ESRCH
        :resolved
      end

      private

      def resolve_owner(claim)
        pid = Integer(claim.fetch("owner_pid"))
        recorded_start = claim.fetch("owner_process_start_time").to_s
        return :unresolved unless Hive::ProcessKill.valid_target_pid?(pid)
        return :resolved unless Hive::ProcessKill.pid_alive?(pid)
        return :unresolved if recorded_start.empty?

        live_start = Hive::ProcessKill.process_start_time(pid)
        return :unresolved if live_start.to_s.empty?

        live_start.to_s == recorded_start ? :unresolved : :resolved
      rescue KeyError, ArgumentError, TypeError
        :unresolved
      end
    end
  end
end
