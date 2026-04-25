require "yaml"
require "fileutils"
require "time"

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

    def update_task_lock(task_folder, additions)
      lock_path = File.join(task_folder, ".lock")
      return unless File.exist?(lock_path)

      data = YAML.safe_load(File.read(lock_path)) || {}
      additions.each { |k, v| data[k.to_s] = v }
      File.write(lock_path, data.to_yaml)
    end

    def with_commit_lock(project_hive_state_path)
      FileUtils.mkdir_p(project_hive_state_path)
      lock_path = File.join(project_hive_state_path, ".commit-lock")
      File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |f|
        f.flock(File::LOCK_EX)
        return yield
      ensure
        f&.flock(File::LOCK_UN)
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

    def process_start_time(pid)
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
  end
end
