require "time"
require "yaml"
require "hive/lock"

module Hive
  # Shared PID-file helpers for long-running hive-owned processes.
  # Consumers provide a `pid_file` method and include this module.
  #
  # The module-level `read`/`alive?` below are the stateless variant: they
  # take an explicit path (or injectable process) and apply no ownership
  # verification, for callers that merely read *another* process's PID file
  # (e.g. `hive bot stop/status`, `hive pairing approve` signalling the bot).
  module PidFile
    # Probe whether `pid` names a live process. EPERM means the process
    # exists but is owned by another user — still alive. The `process:`
    # seam lets callers inject a stub in tests.
    def self.alive?(pid, process: Process)
      process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    # Parse a YAML PID file into a Hash. Returns {} when the file is absent
    # or its top-level document is not a mapping. Lets read/parse errors
    # (Psych::Exception, SystemCallError, IOError) propagate so the caller
    # can apply its own corruption policy.
    def self.read(path)
      return {} unless File.exist?(path)

      # Permit Time so this stateless reader matches the writer and the
      # instance-level `read_pid_file_payload`: a daemon PID file embeds a
      # `process_start_time`/`started_at` Time, which would otherwise raise
      # Psych::DisallowedClass here. Strictly more permissive, never less safe.
      data = YAML.safe_load(File.read(path), permitted_classes: [ Time ]) || {}
      data.is_a?(Hash) ? data : {}
    end

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
