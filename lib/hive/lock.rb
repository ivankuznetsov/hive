require "yaml"
require "fileutils"
require "time"
require "securerandom"

module Hive
  module Lock
    module_function

    def with_task_lock(task_folder, payload = {})
      lock_data = acquire_task_lock(task_folder, payload)
      begin
        yield
      ensure
        release_task_lock(task_folder, lock_id: lock_data.fetch("lock_id"))
      end
    end

    def acquire_task_lock(task_folder, payload = {})
      lock_path = File.join(task_folder, ".lock")
      FileUtils.mkdir_p(task_folder)
      data = base_payload.merge(payload.transform_keys(&:to_s)).merge(
        "lock_id" => SecureRandom.hex(16)
      )

      with_task_lock_guard(lock_path) do
        attempts = 0
        begin
          attempts += 1
          publish_task_lock(lock_path, data)
        rescue Errno::EEXIST
          if stale_lock?(lock_path)
            File.delete(lock_path)
            retry if attempts < 3
          end
          holder = read_task_lock(lock_path)
          raise ConcurrentRunError.new(
            "another hive run is active for #{task_folder} (lock at #{lock_path})",
            holder: holder,
            lock_path: lock_path
          )
        end
      end
      data
    end

    def release_task_lock(task_folder, lock_id:)
      lock_path = File.join(task_folder, ".lock")
      with_task_lock_guard(lock_path) do
        return false unless File.exist?(lock_path)

        current = read_task_lock(lock_path)
        return false unless current && current["lock_id"] == lock_id

        File.delete(lock_path)
        true
      end
    end

    # Atomic read-modify-write to prevent torn reads during stale-lock checks
    # by a concurrent process. Writes via tempfile + rename.
    def update_task_lock(task_folder, additions)
      lock_path = File.join(task_folder, ".lock")
      tmp = nil
      with_task_lock_guard(lock_path) do
        return unless File.exist?(lock_path)

        data = YAML.safe_load(File.read(lock_path)) || {}
        additions.each { |k, v| data[k.to_s] = v }
        tmp = "#{lock_path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
        File.write(tmp, data.to_yaml)
        File.rename(tmp, lock_path)
      end
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    # Serialize lock-path publication, stale replacement, updates, and
    # ownership-checked release on a stable sidecar inode. The guard is held
    # only for these short filesystem operations, never for the task run.
    def with_task_lock_guard(lock_path)
      guard_path = "#{lock_path}.guard"
      File.open(guard_path, File::RDWR | File::CREAT, 0o644) do |guard|
        guard.flock(File::LOCK_EX)
        yield
      end
    end

    # Publish a fully initialized YAML inode with no replacement semantics.
    # A contender can observe either no .lock or the complete payload, never
    # the empty/partial O_EXCL file that older code misclassified as stale.
    def publish_task_lock(lock_path, data)
      tmp = "#{lock_path}.tmp.#{Process.pid}.#{SecureRandom.hex(8)}"
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
        file.write(data.to_yaml)
        file.flush
        file.fsync
      end
      File.link(tmp, lock_path)
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    def read_task_lock(lock_path)
      data = YAML.safe_load(File.read(lock_path), permitted_classes: [ Time ]) || {}
      data.is_a?(Hash) ? data : nil
    rescue StandardError
      nil
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
            raise ConcurrentRunError.new(
              "commit lock at #{lock_path} held longer than #{COMMIT_LOCK_TIMEOUT_SEC}s",
              lock_path: lock_path
            )
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
