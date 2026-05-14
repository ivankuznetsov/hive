require "fileutils"
require "json"
require "shellwords"
require "time"
require "tmpdir"

module Hive
  module Daemon
    # Subprocess management for the daemon: spawn `hive ...` children,
    # capture stdout+stderr to per-task log files, reap completed PIDs,
    # parse the JSON exit envelope when present, and forward signals to
    # PGIDs on shutdown.
    #
    # Pattern matches `Hive::Agent#run!` (lib/hive/agent.rb) — same
    # `Process.spawn(pgroup: true)` + `Process.wait(pid, WNOHANG)`
    # polling. Failures are isolated per child; a segfault in one
    # `hive run` doesn't take the daemon down.
    class ChildSupervisor
      ChildExit = Struct.new(:pid, :exit_code, :project, :slug, :stage, :command,
                             :state_file_path, :started_at, :finished_at, :json_envelope,
                             keyword_init: true)

      def initialize(hive_bin: ENV.fetch("HIVE_BIN", "hive"),
                     log_dir_for_task: nil,
                     dry_run: false)
        @hive_bin = hive_bin
        @dry_run = dry_run
        # Optional injection point: tests pass a lambda taking (project, slug)
        # → an absolute path to write the child's combined stdout/stderr.
        # Falls back to a tmp-style scheme using the project's hive-state
        # directory if the dispatcher doesn't supply one.
        @log_dir_for_task = log_dir_for_task
        # pid → { project, slug, stage, command, started_at, log_path }
        @running = {}
      end

      # Spawn a child process running `command_string`. The string MUST
      # already start with `hive ` (the daemon never invents commands;
      # it consumes status' `suggested_command`). Returns the child PID,
      # or a synthetic non-positive marker in dry-run mode.
      #
      # When dry_run is true, the would-be invocation is recorded but
      # NOT spawned. The dispatcher logs the decision via the Logger;
      # supervisor returns a synthetic PID (-1, -2, ...) so the
      # ConcurrencyController bookkeeping stays consistent across both
      # modes.
      def spawn(command_string:, project:, slug:, stage:,
                hive_state_path: nil, state_file_path: nil, dry_run: nil)
        effective_dry_run = dry_run.nil? ? @dry_run : dry_run

        argv = parse_command(command_string)
        unless argv.first == "hive" || argv.first.end_with?("/hive") ||
               argv.first == File.basename(@hive_bin)
          # Defensive: the supervisor only spawns hive subcommands.
          # An unexpected first token is a dispatcher classifier bug.
          raise ArgumentError, "ChildSupervisor refuses non-hive command: #{command_string.inspect}"
        end
        # Replace literal "hive" with the configured binary so tests
        # can swap in a fixture path via HIVE_BIN.
        argv[0] = @hive_bin

        if effective_dry_run
          @running[next_dry_pid] = {
            project: project, slug: slug, stage: stage,
            command: command_string, state_file_path: state_file_path,
            started_at: Time.now, log_path: nil, dry_run: true
          }
          return @running.keys.last
        end

        log_path = log_path_for(project: project, slug: slug,
                                hive_state_path: hive_state_path)
        FileUtils.mkdir_p(File.dirname(log_path))
        # Open with truncation ("w") so each child run starts a fresh
        # per-task log; logs from prior runs are not preserved here —
        # the daemon's own log file at ~/Dev/hive/logs/daemon.log
        # carries the cross-run history.
        log_io = File.open(log_path, "w")
        log_io.puts("[hive-daemon] #{Time.now.utc.iso8601} spawn argv=#{argv.inspect}")
        log_io.flush

        pid = Process.spawn(*argv, pgroup: true, out: log_io, err: log_io)
        log_io.close

        @running[pid] = {
          project: project, slug: slug, stage: stage,
          command: command_string, state_file_path: state_file_path,
          started_at: Time.now, log_path: log_path, dry_run: false
        }
        pid
      end

      # Reap every child that has exited since the last call. Returns an
      # Array<ChildExit> for the dispatcher to feed into the
      # concurrency controller. Empty array when nothing has completed.
      def reap_all(now: Time.now)
        completed = []
        loop do
          # Process.wait with WNOHANG returns nil when nothing is ready.
          pid, status = Process.wait2(-1, Process::WNOHANG)
          break if pid.nil?
        rescue Errno::ECHILD
          break
        else
          entry = @running.delete(pid)
          # Could be a child we don't track (sub-spawn from a hive run),
          # but since we use pgroup: true, kids of our children should
          # be in their own process groups already. Be defensive anyway.
          next if entry.nil?

          envelope = parse_envelope(entry[:log_path])
          completed << ChildExit.new(
            pid: pid, exit_code: status.exitstatus,
            project: entry[:project], slug: entry[:slug], stage: entry[:stage],
            command: entry[:command], state_file_path: entry[:state_file_path],
            started_at: entry[:started_at], finished_at: now, json_envelope: envelope
          )
        end
        completed
      end

      # Reap any dry-run pseudo-children (their "exit" is synthetic — we
      # report exit 0 immediately on the next reap_all). Used by tests
      # and by --dry-run mode in the dispatcher.
      def reap_dry_run(now: Time.now)
        completed = []
        @running.each do |pid, entry|
          next unless entry[:dry_run]

          completed << ChildExit.new(
            pid: pid, exit_code: 0,
            project: entry[:project], slug: entry[:slug], stage: entry[:stage],
            command: entry[:command], state_file_path: entry[:state_file_path],
            started_at: entry[:started_at], finished_at: now, json_envelope: nil
          )
        end
        completed.each { |c| @running.delete(c.pid) }
        completed
      end

      # Send SIGTERM to every tracked child's process group, wait up to
      # `grace_sec`, then SIGKILL anything still running. Used by the
      # dispatcher's shutdown path.
      def terminate_all(grace_sec: 600)
        return if @running.empty?

        pgids = collect_pgids
        pgids.each { |pgid| safe_kill(:TERM, -pgid) }

        deadline = Time.now + grace_sec
        until @running.empty? || Time.now >= deadline
          reaped = reap_all
          break if reaped.empty? && @running.empty?

          sleep 0.1
        end

        return if @running.empty?

        # Anything still alive gets KILL.
        @running.each_key do |pid|
          pgid = begin
            Process.getpgid(pid)
          rescue Errno::ESRCH
            pid
          end
          safe_kill(:KILL, -pgid)
        end
        # One more reap pass to clear out the killed children.
        reap_all
      end

      def in_flight_pids
        @running.keys
      end

      def in_flight_count
        @running.size
      end

      private

      def parse_command(command_string)
        Shellwords.split(command_string)
      end

      def log_path_for(project:, slug:, hive_state_path:)
        return @log_dir_for_task.call(project, slug) if @log_dir_for_task

        # Fallback: write under <hive_state_path>/logs/<slug>/. The
        # supervisor doesn't know hive-state paths globally; the
        # dispatcher passes one when it has it. If nothing's available
        # we drop into a tmp directory keyed by PID so the file is
        # discoverable but doesn't pollute project state.
        base = hive_state_path ? File.join(hive_state_path, "logs", slug) : nil
        base ||= File.join(Dir.tmpdir, "hive-daemon-logs", project.to_s, slug.to_s)
        ts = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
        File.join(base, "daemon-run-#{ts}-#{Process.pid}.log")
      end

      # Bytes to read from the END of the child log when scanning for
      # the JSON envelope. The envelope is the last line of stdout per
      # `wiki/cli.md`'s `--json` contract; 64 KB is enormously generous
      # for a single JSON document but bounded against a runaway child
      # that wrote gigabytes of prose. PR-40 follow-up review C1.
      ENVELOPE_TAIL_BYTES = 64 * 1024

      def parse_envelope(log_path)
        return nil if log_path.nil? || !File.exist?(log_path)

        tail = read_tail(log_path, ENVELOPE_TAIL_BYTES)
        return nil if tail.nil? || tail.empty?

        # Walk backwards through the tail looking for a line that
        # parses as JSON — earlier lines may contain prose output and
        # the daemon's own [hive-daemon] header line.
        tail.lines.reverse_each do |line|
          line = line.strip
          next if line.empty? || line.start_with?("[hive-daemon]")
          next unless line.start_with?("{")

          begin
            return JSON.parse(line)
          rescue JSON::ParserError
            next
          end
        end
        nil
      end

      # Stream the last `max_bytes` of a file without materializing the
      # whole thing. Discards any partial leading line so JSON parse on
      # the boundary line doesn't fail mid-token. Returns "" when the
      # file is empty.
      def read_tail(path, max_bytes)
        File.open(path, "rb") do |f|
          size = f.size
          start = [ size - max_bytes, 0 ].max
          f.seek(start)
          chunk = f.read
          # If we seeked past byte 0, the first line in `chunk` is
          # almost certainly a partial line — drop it so we never try
          # to JSON-parse a truncated prefix.
          chunk = chunk.split("\n", 2)[1].to_s if start.positive?
          chunk
        end
      rescue Errno::ENOENT, Errno::EACCES, IOError
        nil
      end

      def collect_pgids
        pgids = []
        @running.each_key do |pid|
          pgid = Process.getpgid(pid)
          pgids << pgid
        rescue Errno::ESRCH
          # Process already gone; let reap_all clean it up.
        end
        pgids.uniq
      end

      def safe_kill(signal, target)
        Process.kill(signal, target)
      rescue Errno::ESRCH
        # Already dead — fine.
      rescue Errno::EPERM
        # Shouldn't happen for our own children; log and continue.
      end

      def next_dry_pid
        # Synthetic decreasing PIDs so they never collide with real
        # OS-assigned PIDs (which are positive).
        @next_dry_pid ||= 0
        @next_dry_pid -= 1
        @next_dry_pid
      end
    end
  end
end
