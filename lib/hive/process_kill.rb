require "hive/lock"

module Hive
  module ProcessKill
    TERM_GRACE_SECONDS = 2.0
    KILL_GRACE_SECONDS = 0.2
    POLL_INTERVAL_SECONDS = 0.05

    Result = Struct.new(:pid, :killed, :skipped_reason, keyword_init: true)

    module_function

    def pid_alive?(pid)
      Process.kill(0, Integer(pid))
      true
    rescue ArgumentError, TypeError, Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def process_start_time(pid)
      Hive::Lock.process_start_time(Integer(pid))
    rescue ArgumentError, TypeError
      nil
    end

    def pid_owned_by_recorded_start?(pid, recorded_start_time)
      return true if recorded_start_time.to_s.empty?

      live = process_start_time(pid)
      return true if live.to_s.empty?

      recorded_start_time.to_s == live.to_s
    end

    def terminate_process(pid, recorded_start_time: nil, grace_seconds: TERM_GRACE_SECONDS)
      pid = Integer(pid)
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
      Result.new(pid: pid, killed: !pid_alive?(pid), skipped_reason: nil)
    rescue ArgumentError, TypeError
      Result.new(pid: nil, killed: false, skipped_reason: "invalid_pid")
    rescue Errno::EPERM
      Result.new(pid: pid, killed: false, skipped_reason: "permission_denied")
    end

    def terminate_process_group(pid, recorded_start_time: nil, grace_seconds: TERM_GRACE_SECONDS)
      pid = Integer(pid)
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
      Result.new(pid: pid, killed: !pid_alive?(pid), skipped_reason: nil)
    rescue ArgumentError, TypeError
      Result.new(pid: nil, killed: false, skipped_reason: "invalid_pid")
    rescue Errno::ESRCH
      Result.new(pid: pid, killed: false, skipped_reason: "not_alive")
    rescue Errno::EPERM
      Result.new(pid: pid, killed: false, skipped_reason: "permission_denied")
    end

    def safe_kill(signal, target)
      Process.kill(signal, target)
    rescue Errno::ESRCH, Errno::EPERM
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
