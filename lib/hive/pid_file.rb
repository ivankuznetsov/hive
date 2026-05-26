require "time"
require "yaml"
require "hive/lock"

module Hive
  # Shared PID-file helpers for long-running hive-owned processes.
  # Consumers provide a `pid_file` method and include this module.
  module PidFile
    def read_live_pid
      return nil unless File.exist?(pid_file)

      payload = read_pid_file_payload
      pid = payload && payload["pid"]
      return nil unless pid && pid > 0
      return nil unless pid_alive?(pid)
      return nil unless pid_owned_by_us?(payload, pid)

      pid
    end

    def pid_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def pid_ownership(payload, pid)
      return :unverified if payload.nil?
      return :legacy     if payload["_legacy"]

      recorded = payload["process_start_time"]
      live = Hive::Lock.process_start_time(pid)
      return :unverified if recorded.nil? || live.nil?

      recorded == live ? :verified : :reused
    end

    def pid_owned_by_us?(payload, pid)
      ownership = pid_ownership(payload, pid)
      ownership == :verified || ownership == :legacy
    end

    def read_pid_file_payload
      return nil unless File.exist?(pid_file)

      raw = File.read(pid_file)
      parsed = YAML.safe_load(raw, permitted_classes: [ Time ]) rescue nil
      return parsed if parsed.is_a?(Hash) && parsed["pid"]

      if raw.strip =~ /\A\d+\z/
        return { "pid" => raw.strip.to_i, "process_start_time" => nil, "_legacy" => true }
      end

      nil
    end

    def pid_file_payload(pid, start_time = nil)
      start_time ||= Hive::Lock.process_start_time(pid)
      {
        "pid" => pid,
        "process_start_time" => start_time,
        "started_at" => Time.now.utc.iso8601
      }
    end

    def send_signal_safely(pid, signal)
      Process.kill(signal, pid)
    rescue Errno::ESRCH
      nil
    rescue Errno::EPERM
      warn "hive: insufficient permissions to signal pid #{pid}"
    end
  end
end
