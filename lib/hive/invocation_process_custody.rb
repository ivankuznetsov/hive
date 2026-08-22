require "open3"
require "securerandom"
require "hive/errors"
require "hive/process_kill"

module Hive
  # Process groups are not custody: a tool can call setsid(2), exit its
  # original ancestry, and leave a server behind after its agent finishes.
  # This run-scoped token follows inherited environments across both changes,
  # so cleanup can address only processes created by one invocation.
  class InvocationProcessCustody
    ENVIRONMENT_KEY = "HIVE_INVOCATION_PROCESS_CUSTODY_ID"
    MAX_PROCESSES = 131_072
    MAX_ENVIRONMENT_BYTES = 8 * 1024 * 1024
    TERM_GRACE_SECONDS = 2.0
    KILL_GRACE_SECONDS = 0.5
    POLL_SECONDS = 0.05

    class CleanupError < Hive::Error; end

    def initialize(token: SecureRandom.hex(32), proc_root: "/proc",
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   sleeper: ->(seconds) { sleep(seconds) })
      @token = token.to_s
      @proc_root = proc_root
      @clock = clock
      @sleeper = sleeper
      unless @token.match?(/\A[0-9a-f]{64}\z/)
        raise ArgumentError, "process-custody token must be 32 random bytes"
      end
    end

    def environment
      { ENVIRONMENT_KEY => @token }
    end

    def cleanup!
      terminate_until_empty("TERM", TERM_GRACE_SECONDS)
      terminate_until_empty("KILL", KILL_GRACE_SECONDS)
      remaining = matching_processes
      return true if remaining.empty?

      raise CleanupError,
            "invocation left #{remaining.length} process(es) alive after TERM/KILL"
    end

    private

    def terminate_until_empty(signal, grace_seconds)
      deadline = @clock.call + grace_seconds
      loop do
        targets = matching_processes
        return if targets.empty?

        targets.each { |target| signal_current(signal, target) }
        return if @clock.call >= deadline

        @sleeper.call(POLL_SECONDS)
      end
    end

    def matching_processes
      if RUBY_PLATFORM.include?("linux") && File.directory?(@proc_root)
        procfs_matches
      else
        ps_matches
      end
    end

    def procfs_matches
      entries = Dir.children(@proc_root).grep(/\A\d+\z/)
      raise CleanupError, "process-custody inventory exceeds its bound" if
        entries.length > MAX_PROCESSES

      entries.filter_map do |entry|
        pid = Integer(entry, 10)
        next unless Hive::ProcessKill.valid_target_pid?(pid)
        next if pid == Process.pid

        root = File.join(@proc_root, entry)
        next unless File.stat(root).uid == Process.uid
        next unless environment_matches?(File.join(root, "environ"))

        capture_identity(pid)
      rescue Errno::ENOENT
        nil
      # Same-uid service managers can be deliberately non-dumpable, making
      # their environ unreadable even to their owner. Omit those pre-existing
      # system rows instead of making every invocation fail on systemd hosts;
      # ordinary descendants retain readable procfs environments here.
      rescue Errno::EACCES, Errno::EPERM, Errno::EIO
        nil
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::EIO => e
      raise CleanupError, "process-custody procfs is unavailable: #{e.class}"
    end

    def environment_matches?(path)
      # Ruby returns nil (rather than an empty String) when a length-bounded
      # read starts at EOF. Kernel threads and short-lived system rows can
      # legitimately expose an empty environ, and simply cannot match our
      # invocation token.
      bytes = File.binread(path, MAX_ENVIRONMENT_BYTES + 1) || ""
      if bytes.bytesize > MAX_ENVIRONMENT_BYTES
        raise CleanupError, "process-custody environment exceeds its bound"
      end

      bytes.split("\0", -1).include?("#{ENVIRONMENT_KEY}=#{@token}")
    end

    # macOS/BSD have no procfs by default. `ps xeww` limits the inventory to
    # this uid and appends the complete environment to each command row.
    def ps_matches
      ps = Hive::ProcessKill::SYSTEM_PS_PATHS.find do |path|
        File.file?(path) && File.executable?(path)
      end
      raise CleanupError, "process-custody ps inventory is unavailable" unless ps

      out, _err, status = Open3.capture3(ps, "xeww", "-o", "pid=", "-o", "command=")
      raise CleanupError, "process-custody ps inventory failed" unless status.success?
      raise CleanupError, "process-custody inventory exceeds its bound" if
        out.lines.length > MAX_PROCESSES

      needle = /(?:\A|\s)#{Regexp.escape(ENVIRONMENT_KEY)}=#{Regexp.escape(@token)}(?:\s|\z)/
      out.each_line.filter_map do |line|
        pid_text, command = line.strip.split(/\s+/, 2)
        pid = Integer(pid_text, exception: false)
        next unless Hive::ProcessKill.valid_target_pid?(pid)
        next if pid == Process.pid || !command&.match?(needle)

        capture_identity(pid)
      end
    rescue SystemCallError => e
      raise CleanupError, "process-custody ps inventory is unavailable: #{e.class}"
    end

    def capture_identity(pid)
      start_time = Hive::ProcessKill.process_start_time(pid)
      if start_time.to_s.empty?
        raise CleanupError, "process-custody identity is unavailable for pid #{pid}"
      end

      { pid: pid, start_time: start_time }
    end

    def signal_current(signal, target)
      return unless Hive::ProcessKill.captured_process_current?(
        target, require_identity: true
      )

      Process.kill(signal, target.fetch(:pid))
    rescue Errno::ESRCH
      nil
    rescue Errno::EPERM
      raise CleanupError,
            "process-custody cannot signal same-user pid #{target.fetch(:pid)}"
    end
  end
end
