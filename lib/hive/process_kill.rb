require "hive/lock"

module Hive
  module ProcessKill
    TERM_GRACE_SECONDS = 2.0
    KILL_GRACE_SECONDS = 0.2
    POLL_INTERVAL_SECONDS = 0.05

    Result = Struct.new(:pid, :killed, :skipped_reason, keyword_init: true)

    module_function

    # A PID of 0 means the current process group when passed to
    # Process.kill, and 1 is init. A malformed `.lock` or marker
    # leaking either through would target ourselves (or PID 1) instead
    # of an agent — refuse outright.
    def valid_target_pid?(pid)
      pid.is_a?(Integer) && pid > 1
    end

    def pid_alive?(pid)
      Process.kill(0, Integer(pid))
      true
    rescue ArgumentError, TypeError, Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    # Defense in depth for the PID-reuse guard: if the start-time lookup
    # raises (containerised /proc, missing ps, malformed lock metadata)
    # we return nil here and `pid_owned_by_recorded_start?` falls
    # through to "trust the recorded pid". Combined with the empty-live
    # short-circuit this means a hardened guard requires BOTH a
    # recorded start-time and a working start-time source.
    def process_start_time(pid)
      Hive::Lock.process_start_time(Integer(pid))
    rescue ArgumentError, TypeError
      nil
    end

    # Linux/macOS reuse PIDs aggressively under load. The recorded
    # start-time pinned at lock-acquire time is the discriminator: if
    # the live process boots with a different start-time, the original
    # agent has exited and the PID belongs to an unrelated process.
    def pid_owned_by_recorded_start?(pid, recorded_start_time)
      return true if recorded_start_time.to_s.empty?

      live = process_start_time(pid)
      return true if live.to_s.empty?

      recorded_start_time.to_s == live.to_s
    end

    def terminate_process(pid, recorded_start_time: nil, grace_seconds: TERM_GRACE_SECONDS)
      pid = Integer(pid)
      return Result.new(pid: pid, killed: false, skipped_reason: "invalid_pid") unless valid_target_pid?(pid)
      return Result.new(pid: pid, killed: false, skipped_reason: "not_alive") unless pid_alive?(pid)

      unless pid_owned_by_recorded_start?(pid, recorded_start_time)
        return Result.new(pid: pid, killed: false, skipped_reason: "pid_reuse_guard")
      end

      safe_kill("TERM", pid)
      wait_until_dead(pid, grace_seconds)
      if pid_alive?(pid)
        safe_kill("KILL", pid)
        wait_until_dead(pid, KILL_GRACE_SECONDS)
      end
      killed = !pid_alive?(pid)
      Result.new(pid: pid, killed: killed, skipped_reason: killed ? nil : "kill_failed")
    rescue ArgumentError, TypeError
      Result.new(pid: nil, killed: false, skipped_reason: "invalid_pid")
    rescue Errno::EPERM
      Result.new(pid: pid, killed: false, skipped_reason: "permission_denied")
    end

    def terminate_process_group(pid, recorded_start_time: nil, grace_seconds: TERM_GRACE_SECONDS)
      pid = Integer(pid)
      return Result.new(pid: pid, killed: false, skipped_reason: "invalid_pid") unless valid_target_pid?(pid)
      return Result.new(pid: pid, killed: false, skipped_reason: "not_alive") unless pid_alive?(pid)

      unless pid_owned_by_recorded_start?(pid, recorded_start_time)
        return Result.new(pid: pid, killed: false, skipped_reason: "pid_reuse_guard")
      end

      pgid = Process.getpgid(pid)
      safe_kill("TERM", -pgid)
      wait_until_dead(pid, grace_seconds)
      if pid_alive?(pid)
        safe_kill("KILL", -pgid)
        wait_until_dead(pid, KILL_GRACE_SECONDS)
      end
      killed = !pid_alive?(pid)
      Result.new(pid: pid, killed: killed, skipped_reason: killed ? nil : "kill_failed")
    rescue ArgumentError, TypeError
      Result.new(pid: nil, killed: false, skipped_reason: "invalid_pid")
    rescue Errno::ESRCH
      Result.new(pid: pid, killed: false, skipped_reason: "not_alive")
    rescue Errno::EPERM
      Result.new(pid: pid, killed: false, skipped_reason: "permission_denied")
    end

    def safe_kill(signal, target)
      Process.kill(signal, target)
    rescue Errno::ESRCH
      nil
    end

    def wait_until_dead(pid, seconds)
      deadline = Time.now + seconds
      while Time.now < deadline
        return true if reap_if_child_exited(pid)
        return true unless pid_alive?(pid)

        sleep POLL_INTERVAL_SECONDS
      end
      reap_if_child_exited(pid) || !pid_alive?(pid)
    end

    def reap_if_child_exited(pid)
      waited = Process.waitpid(pid, Process::WNOHANG)
      !waited.nil?
    rescue Errno::ECHILD
      false
    end
  end
end
