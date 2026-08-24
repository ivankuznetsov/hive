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

    # Stateless positive-Integer boundary over any hive-owned PID file.
    # Returns the PID when the file parses to the payload the lifecycle
    # owner writes (`{pid:, process_start_time:, started_at:}`) or to a
    # legacy bare-integer doc; nil for a missing, unreadable, corrupt, or
    # non-positive payload. Consumers that only need the pid (e.g.
    # `hive uninstall` signalling a foreground daemon) must go through
    # here instead of re-implementing the on-disk format — the earlier
    # `File.read.strip.to_i` in Uninstall parsed the YAML doc as PID 0
    # and silently skipped the shutdown.
    def self.read_pid(path)
      return nil unless File.exist?(path)

      raw = File.read(path)
      parsed = YAML.safe_load(raw, permitted_classes: [ Time ]) rescue nil
      pid = parsed.is_a?(Hash) ? parsed["pid"] : parsed
      return nil unless pid.is_a?(Integer) && pid.positive?

      pid
    rescue SystemCallError, IOError
      nil
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

    # Delegate to the module-level `alive?` so the liveness/EPERM/ESRCH policy
    # lives in exactly one place — a future change to signal probing touches one
    # method, not two that must be kept byte-identical.
    def pid_alive?(pid)
      Hive::PidFile.alive?(pid)
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

    # Deliberately NOT a thin wrapper over the stateless `self.read`: this
    # ownership-aware reader has a different contract that callers depend on —
    # it returns nil (not {}) when the file is absent, swallows parse errors to
    # nil instead of propagating them, and still accepts a legacy bare-integer
    # PID file. Collapsing it into `self.read` would shift all three behaviors.
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
