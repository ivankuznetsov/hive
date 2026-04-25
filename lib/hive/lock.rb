require "yaml"
require "fileutils"
require "time"
require "securerandom"

module Hive
  module Lock
    module_function

    def with_task_lock(task_folder, payload = {})
      acquire_task_lock(task_folder, payload)
      begin
        yield
      ensure
        release_task_lock(task_folder)
      end
    end

    def acquire_task_lock(task_folder, payload = {})
      lock_path = File.join(task_folder, ".lock")
      FileUtils.mkdir_p(task_folder)
      data = base_payload.merge(payload.transform_keys(&:to_s))

      attempts = 0
      begin
        attempts += 1
        File.open(lock_path, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |f|
          f.write(data.to_yaml)
        end
      rescue Errno::EEXIST
        if stale_lock?(lock_path)
          File.delete(lock_path)
          retry if attempts < 3
        end
        raise ConcurrentRunError, "another hive run is active for #{task_folder} (lock at #{lock_path})"
      end
      data
    end

    def release_task_lock(task_folder)
      lock_path = File.join(task_folder, ".lock")
      File.delete(lock_path) if File.exist?(lock_path)
    end

    # Atomic read-modify-write to prevent torn reads during stale-lock checks
    # by a concurrent process. Writes via tempfile + rename.
    def update_task_lock(task_folder, additions)
      lock_path = File.join(task_folder, ".lock")
      return unless File.exist?(lock_path)

      data = YAML.safe_load(File.read(lock_path)) || {}
      additions.each { |k, v| data[k.to_s] = v }
      tmp = "#{lock_path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
      File.write(tmp, data.to_yaml)
      File.rename(tmp, lock_path)
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    COMMIT_LOCK_TIMEOUT_SEC = 30

    # Bounded acquire — flock(LOCK_EX) without timeout would hang forever if a
    # frozen 45-min agent holds the lock. Poll non-blocking with a deadline.
    def with_commit_lock(project_hive_state_path)
      FileUtils.mkdir_p(project_hive_state_path)
      lock_path = File.join(project_hive_state_path, ".commit-lock")
      File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |f|
        deadline = Time.now + COMMIT_LOCK_TIMEOUT_SEC
        until f.flock(File::LOCK_EX | File::LOCK_NB)
          if Time.now >= deadline
            raise ConcurrentRunError,
                  "commit lock at #{lock_path} held longer than #{COMMIT_LOCK_TIMEOUT_SEC}s"
          end

          sleep 0.2
        end
        return yield
      end
    end

    def base_payload
      {
        "pid" => Process.pid,
        "started_at" => Time.now.utc.iso8601,
        "process_start_time" => process_start_time(Process.pid)
      }
    end

    def stale_lock?(lock_path)
      raw = File.read(lock_path)
      data = begin
        YAML.safe_load(raw) || {}
      rescue StandardError
        return true
      end
      return true unless data.is_a?(Hash)

      pid = data["pid"]
      return true unless pid.is_a?(Integer)

      begin
        Process.kill(0, pid)
      rescue Errno::ESRCH
        return true
      rescue Errno::EPERM
        return false
      end

      recorded = data["process_start_time"]
      live = process_start_time(pid)
      return true if recorded && live && recorded != live

      false
    rescue Errno::ENOENT
      true
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

    def ps_lstart_start_time(pid)
      out = `ps -o lstart= -p #{pid.to_i} 2>/dev/null`.strip
      out.empty? ? nil : out
    rescue StandardError
      nil
    end
  end
end
