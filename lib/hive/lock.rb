require "fileutils"
require "time"
require "hive/runtime_control_plane/task_lease_repository"

module Hive
  module Lock
    module_function

    PS_LSTART_TIMEOUT_SECONDS = 0.25

    def with_task_lock(task_folder, payload = nil, create: true, **payload_keywords)
      payload = (payload || {}).merge(payload_keywords)
      lock_key = task_lease_repository.lease_key(task_folder)
      held = (Thread.current[:hive_task_locks] ||= {})
      if held.dig(lock_key, :pid) == Process.pid
        entry = held.fetch(lock_key)
        entry[:depth] += 1
        begin
          return yield
        ensure
          entry[:depth] -= 1
        end
      end

      held.delete(lock_key)
      lock_data = acquire_task_lock(task_folder, payload, create: create)
      held[lock_key] = { depth: 1, lock_id: lock_data.fetch("lock_id"), pid: Process.pid }
      begin
        yield
      ensure
        entry = held.fetch(lock_key)
        entry[:depth] -= 1
        if entry[:depth].zero?
          held.delete(lock_key)
          release_task_lock(task_folder, lock_id: entry.fetch(:lock_id))
        end
      end
    end

    def task_lock_held?(task_folder)
      key = task_lease_repository.lease_key(task_folder)
      Thread.current[:hive_task_locks].to_h.dig(key, :pid) == Process.pid
    rescue RuntimeControlPlane::IdentityError
      false
    end

    def acquire_task_lock(task_folder, payload = nil, create: true, **payload_keywords)
      require "hive/attempts/context"

      payload = (payload || {}).merge(payload_keywords)
      data = base_payload
             .merge(payload.transform_keys(&:to_s))
             .merge(Hive::Attempts::Context.projection)
      task_lease_repository.acquire(task_folder, data, create: create)
    end

    def release_task_lock(task_folder, lock_id:)
      task_lease_repository.release(task_folder, lock_id: lock_id)
    end

    # Atomic read-modify-write to prevent torn reads during stale-lock checks
    # by a concurrent process. Only the current thread's fenced holder nonce
    # can mutate the lease payload.
    def update_task_lock(task_folder, additions)
      key = task_lease_repository.lease_key(task_folder)
      entry = Thread.current[:hive_task_locks].to_h[key]
      unless entry && entry[:pid] == Process.pid
        raise ConcurrentRunError.new(
          "task lease update requires ownership",
          lock_path: "runtime-control-plane:task:#{key}"
        )
      end

      task_lease_repository.update(
        task_folder, additions, lock_id: entry.fetch(:lock_id)
      )
    end

    def read_task_lock(task_folder_or_lock)
      task_lease_repository.read(task_folder_or_lock)
    end

    # Drop a completed child only when the lease still names that exact
    # process identity. A later child may already have replaced the recorded
    # PID, so an unconditional update would erase the new owner's liveness
    # evidence.
    def clear_task_lock_child(task_folder, pid:, process_start_time:)
      key = task_lease_repository.lease_key(task_folder)
      entry = Thread.current[:hive_task_locks].to_h[key]
      return false unless entry && entry[:pid] == Process.pid

      task_lease_repository.clear_child(
        task_folder, pid: pid, process_start_time: process_start_time,
        lock_id: entry.fetch(:lock_id)
      )
    rescue RuntimeControlPlane::IdentityError
      false
    end

    COMMIT_LOCK_TIMEOUT_SEC = 30

    # Bounded acquire — flock(LOCK_EX) without timeout would hang forever if a
    # frozen 45-min agent holds the lock. Poll non-blocking with a deadline.
    def with_commit_lock(project_hive_state_path, timeout: COMMIT_LOCK_TIMEOUT_SEC)
      FileUtils.mkdir_p(project_hive_state_path)
      lock_path = File.join(project_hive_state_path, ".commit-lock")
      lock_key = File.realpath(project_hive_state_path)
      held = (Thread.current[:hive_commit_locks] ||= {})
      return yield if held[lock_key] == Process.pid

      File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |f|
        deadline = Time.now + timeout
        until f.flock(File::LOCK_EX | File::LOCK_NB)
          if Time.now >= deadline
            raise ConcurrentRunError.new(
              "commit lock at #{lock_path} held longer than #{timeout}s",
              lock_path: lock_path
            )
          end

          sleep [ 0.2, deadline - Time.now ].min.clamp(0, 0.2)
        end
        held[lock_key] = Process.pid
        begin
          return yield
        ensure
          held.delete(lock_key) if held[lock_key] == Process.pid
        end
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def base_payload
      {
        "pid" => Process.pid,
        "started_at" => Time.now.utc.iso8601,
        "process_start_time" => process_start_time(Process.pid)
      }
    end

    # PID-reuse defense: capture a process start time so a re-used PID looks
    # different from the original. Linux uses /proc/<pid>/stat field 22;
    # macOS / BSD have no /proc, so fall back to `ps -o lstart=`. Returns
    # nil only when neither source works (containerised /proc, missing ps).
    def process_start_time(pid)
      proc_stat_start_time(pid) || ps_lstart_start_time(pid)
    end

    def proc_stat_start_time(pid)
      stat_path = "/proc/#{pid}/stat"
      return nil unless File.exist?(stat_path)

      data = File.read(stat_path)
      # Format: pid (comm) state ppid pgrp ... starttime (field 22)
      tail = data.split(") ").last
      return nil unless tail

      fields = tail.split(/\s+/)
      fields[19] # starttime is field 22 overall, but tail starts after "(comm) ", so index 19 = field 22 - 3
    rescue Errno::EACCES, Errno::ENOENT
      nil
    end

    def ps_lstart_start_time(pid, timeout: PS_LSTART_TIMEOUT_SECONDS)
      reader, writer = IO.pipe
      child_pid = Process.spawn(
        "ps", "-o", "lstart=", "-p", pid.to_i.to_s,
        out: writer, err: File::NULL
      )
      writer.close
      status = wait_for_process(child_pid, timeout)
      unless status
        terminate_and_detach(child_pid)
        child_pid = nil
        return nil
      end
      child_pid = nil
      return nil unless status.success?

      out = reader.read(4_097)
      return nil if out.bytesize > 4_096

      out = out.strip
      out.empty? ? nil : out
    rescue StandardError
      nil
    ensure
      terminate_and_detach(child_pid) if child_pid
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
    end

    def wait_for_process(pid, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        result = Process.waitpid2(pid, Process::WNOHANG)
        return result.last if result

        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return nil unless remaining.positive?

        IO.select(nil, nil, nil, [ remaining, 0.01 ].min)
      end
    end

    def terminate_and_detach(pid)
      begin
        Process.kill("KILL", pid)
      rescue SystemCallError
        nil
      end
      Process.detach(pid)
    rescue Errno::ECHILD
      nil
    end

    def task_lease_repository
      @task_lease_repository ||= RuntimeControlPlane::TaskLeaseRepository.new(
        process_start_time: method(:process_start_time),
        process_alive: method(:process_identity_alive?)
      )
    end

    def task_lease_repository=(repository)
      @task_lease_repository = repository
    end

    def process_identity_alive?(pid, recorded_start_time:)
      Process.kill(0, pid)
      live = process_start_time(pid)
      recorded_start_time.nil? || live.nil? || recorded_start_time == live
    rescue Errno::ESRCH, RangeError
      false
    rescue Errno::EPERM
      true
    end

    private_class_method :wait_for_process, :terminate_and_detach, :process_identity_alive?
  end
end
