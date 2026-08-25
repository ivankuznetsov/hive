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

    # Parse raw PID-file bytes into a lifecycle payload Hash: either the
    # mapping the lifecycle owner writes (`{pid:, process_start_time:,
    # started_at:}`) or a legacy bare-integer doc wrapped as `{pid:,
    # process_start_time: nil, "_legacy" => true}`. Returns nil when the
    # document is corrupt or not a payload the owner could have written.
    def self.parse_payload(raw)
      parsed = YAML.safe_load(raw, permitted_classes: [ Time ]) rescue nil
      return parsed if parsed.is_a?(Hash) && parsed["pid"]

      if raw.strip =~ /\A\d+\z/
        return { "pid" => raw.strip.to_i, "process_start_time" => nil, "_legacy" => true }
      end

      nil
    end

    # Tri-state ownership policy over a parsed payload, shared by every
    # signalling caller so PID-reuse defense lives in exactly one place:
    #   :verified   → recorded start time matches the live process
    #   :legacy     → pre-identity bare-integer doc (best effort)
    #   :reused     → start time mismatch; the PID now names another process
    #   :unverified → no recorded/live start time; identity cannot be proven
    def self.ownership(payload, pid)
      return :unverified if payload.nil?
      return :legacy     if payload["_legacy"]

      recorded = payload["process_start_time"]
      live = Hive::Lock.process_start_time(pid)
      return :unverified if recorded.nil? || live.nil?

      recorded == live ? :verified : :reused
    end

    # Ownership-aware shutdown boundary for callers that read *another*
    # hive process's PID file and want it stopped (e.g. `hive uninstall`
    # TERM-ing a foreground daemon before purge). Never re-implement this
    # at the call site: the owner writes a YAML process-identity payload,
    # a bare-integer parse of that doc reads PID 0 (a silent no-op), and a
    # numeric PID whose start time no longer matches may belong to an
    # unrelated process — signalling it is bystander harm.
    #
    # Returns `{ status:, pid: }` where status is one of:
    #   :absent     no PID file at +path+
    #   :malformed  unreadable/corrupt/non-positive payload
    #   :stale      payload PID is not alive (or died mid-stop)
    #   :reused     PID is alive but its start time mismatches the record
    #   :unverified ownership cannot be proven; refusing to signal
    #   :signalled  ownership verified; +signal+ delivered
    def self.stop(path, signal: "TERM", process: Process)
      return { status: :absent, pid: nil } unless File.exist?(path)

      payload = begin
        parse_payload(File.read(path))
      rescue SystemCallError, IOError
        nil
      end
      pid = payload && payload["pid"]
      return { status: :malformed, pid: nil } unless pid.is_a?(Integer) && pid.positive?
      return { status: :stale, pid: pid } unless alive?(pid, process: process)

      case ownership(payload, pid)
      when :reused     then return { status: :reused, pid: pid }
      when :unverified then return { status: :unverified, pid: pid }
      end

      begin
        process.kill(signal, pid)
        { status: :signalled, pid: pid }
      rescue Errno::ESRCH
        { status: :stale, pid: pid }
      rescue Errno::EPERM
        warn "hive: insufficient permissions to signal pid #{pid}"
        { status: :unverified, pid: pid }
      end
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

    # Delegate to the module-level tri-state so the reuse/unverified
    # policy lives in exactly one place, mirroring `pid_alive?`.
    def pid_ownership(payload, pid)
      Hive::PidFile.ownership(payload, pid)
    end

    def pid_owned_by_us?(payload, pid)
      ownership = pid_ownership(payload, pid)
      ownership == :verified || ownership == :legacy
    end

    # Deliberately NOT a thin wrapper over the stateless `self.read`: this
    # ownership-aware reader has a different contract that callers depend on —
    # it returns nil (not {}) when the file is absent, still accepts a legacy
    # bare-integer PID file, and yields the `_legacy` marker the tri-state
    # policy keys on. The parsing itself delegates to `self.parse_payload` so
    # the on-disk format lives in exactly one place.
    def read_pid_file_payload
      return nil unless File.exist?(pid_file)

      Hive::PidFile.parse_payload(File.read(pid_file))
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
