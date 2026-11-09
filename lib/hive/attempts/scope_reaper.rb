require "digest"
require "json"

module Hive
  module Attempts
    # Ends what is left of one durable attempt's `hive-attempt-*.scope` after
    # the worker is gone. The worker process group is already signalled by the
    # supervisor, but a tool can leave it: `podman run` hands the container to
    # `conmon` and `pasta`, which call setsid(2) and stay in the scope cgroup.
    # systemd keeps a scope active while any process remains in it, so one
    # leftover kept a finished attempt's scope `active (running)` for hours.
    #
    # The supervisor is the scope's first process and stays at the scope root,
    # so this runs inside the scope: SIGTERM to every other member, a bounded
    # grace, then SIGKILL. When the last process exits, systemd collects the
    # scope (it is launched with `--collect`).
    #
    # Only this attempt's own scope is touched. The supervisor's cgroup must
    # end in the unit derived from its own attempt id, and every pid is
    # re-checked against that cgroup right before it is signalled. Anywhere
    # else (no systemd scope, macOS, a test process) the reaper is a no-op.
    class ScopeReaper
      UNIT_PREFIX = "hive-attempt-".freeze
      POLL_SEC = 0.05
      KILL_WAIT_SEC = 2.0
      MAX_MEMBERS = 4096
      COMM_BYTES = 64

      Result = Data.define(:status, :unit, :reaped, :survivors, :error) do
        # Whether anything was left for the operator to know about.
        def notable? = %w[reaped incomplete unavailable].include?(status)

        def journal_line
          payload = { "unit" => unit, "status" => status, "reaped" => reaped, "survivors" => survivors }
          payload["error"] = error if error
          "hive-attempt: scope_leftovers #{JSON.generate(payload)}\n"
        end
      end

      # The transient unit name DetachedLauncher gives one attempt.
      def self.unit_name(attempt_id)
        "#{UNIT_PREFIX}#{Digest::SHA256.hexdigest(attempt_id.to_s)[0, 24]}"
      end

      def initialize(attempt_id:, proc_root: "/proc", cgroup_root: "/sys/fs/cgroup",
                     self_pid: Process.pid, signaller: nil, monotonic: nil, sleeper: nil)
        @unit = "#{self.class.unit_name(attempt_id)}.scope"
        @proc_root = proc_root
        @cgroup_root = cgroup_root
        @self_pid = self_pid
        @signaller = signaller || Process.method(:kill)
        @monotonic = monotonic || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @sleeper = sleeper || method(:sleep)
      end

      def reap(term_grace_sec:, kill_wait_sec: KILL_WAIT_SEC)
        domain = own_scope_path
        return result("unscoped") unless domain

        seen = {}
        record = ->(pids) { pids.each { |pid| seen[pid] ||= command_name(pid) } }
        initial = members(domain)
        return result("clean") if initial.empty?

        record.call(initial)
        terminate(domain, "TERM", term_grace_sec, record)
        terminate(domain, "KILL", kill_wait_sec, record)
        survivors = members(domain)
        reaped = seen.reject { |pid, _| survivors.include?(pid) }
        result(
          survivors.empty? ? "reaped" : "incomplete",
          reaped: describe(reaped), survivors: describe(seen.slice(*survivors))
        )
      rescue SystemCallError, IOError, ArgumentError => e
        result("unavailable", reaped: describe(seen || {}), error: "#{e.class}: #{e.message}")
      end

      private

      def result(status, reaped: [], survivors: [], error: nil)
        Result.new(status: status, unit: @unit, reaped: reaped, survivors: survivors, error: error)
      end

      def describe(processes)
        processes.sort.map { |pid, comm| { "pid" => pid, "comm" => comm } }
      end

      # Signal every current member until the scope is empty or the grace
      # ends. Re-reading each round also catches processes forked meanwhile.
      def terminate(domain, signal, grace_sec, record)
        deadline = @monotonic.call + [ grace_sec.to_f, 0.0 ].max
        loop do
          targets = members(domain)
          return if targets.empty?

          record.call(targets)
          targets.each { |pid| signal_member(domain, signal, pid) }
          return if @monotonic.call >= deadline

          @sleeper.call(POLL_SEC)
        end
      end

      # The pid is re-read against the scope right before the signal, so a
      # pid that exited and was reused outside the scope is never signalled.
      def signal_member(domain, signal, pid)
        return unless within?(cgroup_path(pid), domain)

        @signaller.call(signal, pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      # The supervisor's own cgroup when, and only when, it is this attempt's
      # scope root. A sub-cgroup or another attempt's scope is not ours.
      def own_scope_path
        path = cgroup_path(@self_pid)
        return nil unless path && File.basename(path) == @unit

        path
      end

      def members(domain)
        directory = File.join(@cgroup_root, domain)
        files = Dir.glob(File.join(directory, "**", "cgroup.procs"))
        pids = files.flat_map { |file| read_pids(file) }.uniq
        raise ArgumentError, "attempt scope membership exceeds #{MAX_MEMBERS}" if pids.length > MAX_MEMBERS

        pids.reject { |pid| pid == @self_pid }.sort
      end

      def read_pids(file)
        File.readlines(file, chomp: true).filter_map { |line| Integer(line, exception: false) }
      rescue Errno::ENOENT, Errno::ENODEV
        []
      end

      def cgroup_path(pid)
        line = File.foreach(File.join(@proc_root, pid.to_s, "cgroup")).find { |entry| entry.start_with?("0::") }
        line&.split("::", 2)&.last&.strip
      rescue Errno::ENOENT, Errno::ESRCH
        nil
      end

      def within?(path, domain)
        !path.nil? && (path == domain || path.start_with?("#{domain}/"))
      end

      def command_name(pid)
        File.read(File.join(@proc_root, pid.to_s, "comm"), COMM_BYTES).to_s.strip
      rescue SystemCallError, IOError
        ""
      end
    end
  end
end
