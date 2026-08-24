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
    rescue Errno::ESRCH, RangeError
      false
    rescue Errno::EPERM
      true
    end

    # Identity-aware liveness for observations that must not mistake a reused
    # PID for the process recorded on disk. Legacy callers retain PID-only
    # behavior by default; strict contracts pass require_start_time: true.
    def self.identity_alive?(pid, recorded_start_time: nil, require_start_time: false,
                             process: Process,
                             start_time_reader: Hive::Lock.method(:process_start_time))
      return false unless pid.is_a?(Integer) && pid.positive?
      return false unless alive?(pid, process: process)
      return !require_start_time if recorded_start_time.nil?

      start_time_reader.call(pid) == recorded_start_time
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
    def read_pid_file_payload(max_bytes: nil)
      return nil unless File.exist?(pid_file)

      raw = max_bytes ? read_bounded_pid_file(max_bytes) : File.read(pid_file)
      return nil unless raw

      parsed = YAML.safe_load(raw, permitted_classes: [ Time ]) rescue nil
      return parsed if parsed.is_a?(Hash) && parsed["pid"]

      if raw.strip =~ /\A\d+\z/
        return { "pid" => raw.strip.to_i, "process_start_time" => nil, "_legacy" => true }
      end

      nil
    end

    def read_bounded_pid_file(max_bytes)
      flags = File::RDONLY
      nofollow = File.const_defined?(:NOFOLLOW)
      flags |= File::NOFOLLOW if nofollow
      flags |= File::NONBLOCK if File.const_defined?(:NONBLOCK)

      File.open(pid_file, flags) do |file|
        opened = file.stat
        return nil unless opened.file? && opened.size <= max_bytes

        unless nofollow
          entry = File.lstat(pid_file)
          return nil if entry.symlink? || entry.dev != opened.dev || entry.ino != opened.ino
        end

        raw = file.read(max_bytes + 1)
        raw if raw.bytesize <= max_bytes
      end
    rescue SystemCallError, IOError
      nil
    end
    private :read_bounded_pid_file

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
