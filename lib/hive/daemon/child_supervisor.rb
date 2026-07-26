require "fileutils"
require "json"
require "shellwords"
require "time"
require "tmpdir"
require "hive/lock"
require "hive/process_kill"

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
                             :request_id, :dispatch_token,
                             keyword_init: true)

      # A child that breached its wall-clock timeout. The dispatcher logs
      # one `:child_timeout` event per action (`:term` on first breach,
      # `:kill` if the grace window elapses without exit).
      TimeoutAction = Struct.new(:pid, :project, :slug, :stage, :command,
                                 :action, :elapsed_sec, :timeout_sec,
                                 keyword_init: true)

      # R-02 (PR #241 ce-code-review): default TERM→KILL escalation window
      # when the daemon config doesn't supply one. A wedged child gets
      # SIGTERM, then SIGKILL `kill_grace_sec` later if it ignored TERM.
      DEFAULT_KILL_GRACE_SEC = 30

      def initialize(hive_bin: ENV.fetch("HIVE_BIN", "hive"),
                     log_dir_for_task: nil,
                     dry_run: false,
                     default_timeout_sec: 0,
                     verb_timeouts: {},
                     kill_grace_sec: DEFAULT_KILL_GRACE_SEC)
        @hive_bin = hive_bin
        @dry_run = dry_run
        # Optional injection point: tests pass a lambda taking (project, slug)
        # → an absolute path to write the child's combined stdout/stderr.
        # Falls back to a tmp-style scheme if the dispatcher does not supply
        # Hive's durable state directory for this spawn.
        @log_dir_for_task = log_dir_for_task
        # R-02 per-verb wall-clock timeout. `default_timeout_sec` applies
        # to every spawned child unless `verb_timeouts[verb]` overrides
        # it; a resolved timeout of 0 (or nil) disables the cap for that
        # child (the historical behaviour — children ran unbounded until
        # daemon shutdown). The timeout is resolved AT SPAWN and frozen on
        # the running entry so a mid-run config reload never retroactively
        # kills an in-flight child.
        @default_timeout_sec = default_timeout_sec.to_i
        @verb_timeouts = (verb_timeouts || {}).each_with_object({}) do |(verb, secs), acc|
          acc[verb.to_s] = secs.to_i
        end
        @kill_grace_sec = kill_grace_sec.to_i
        # pid → { project, slug, stage, command, started_at, log_path, pgid,
        #         timeout_sec, terminating_at, killed }
        @running = {}
        @forced_completions = []
      end

      # Resolve the wall-clock timeout (seconds) for a hive verb. A
      # per-verb override wins over the default; 0 means "no cap".
      def timeout_for_verb(verb)
        @verb_timeouts.fetch(verb.to_s, @default_timeout_sec)
      end

      # Re-read the timeout knobs after a SIGHUP config reload. Only
      # affects children spawned AFTER the reload — in-flight children
      # keep the timeout frozen on their running entry at spawn time, so
      # a reload never retroactively kills (or reprieves) a live run.
      def update_timeouts(default_timeout_sec:, verb_timeouts:, kill_grace_sec:)
        @default_timeout_sec = default_timeout_sec.to_i
        @verb_timeouts = (verb_timeouts || {}).each_with_object({}) do |(verb, secs), acc|
          acc[verb.to_s] = secs.to_i
        end
        @kill_grace_sec = kill_grace_sec.to_i
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
                log_state_path: nil, state_file_path: nil, dry_run: nil,
                request_id: nil, dispatch_token: nil)
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

        timeout_sec = timeout_for_verb(argv_verb(argv))

        if effective_dry_run
          @running[next_dry_pid] = {
            project: project, slug: slug, stage: stage,
            command: command_string, state_file_path: state_file_path,
            started_at: Time.now, log_path: nil, dry_run: true,
            request_id: request_id, dispatch_token: dispatch_token, timeout_sec: timeout_sec
          }
          return @running.keys.last
        end

        log_path = log_path_for(project: project, slug: slug,
                                log_state_path: log_state_path)
        FileUtils.mkdir_p(File.dirname(log_path))
        # Open with truncation ("w") so the durable per-task capture starts
        # fresh on every child run. The daemon's own log file at
        # ~/Dev/hive/logs/daemon.log carries the cross-run history.
        log_io = File.open(log_path, "w")
        log_io.puts("[hive-daemon] #{Time.now.utc.iso8601} spawn argv=#{argv.inspect}")
        log_io.flush

        pid = Process.spawn(*argv, pgroup: true, out: log_io, err: log_io)
        log_io.close

        @running[pid] = {
          project: project, slug: slug, stage: stage,
          command: command_string, state_file_path: state_file_path,
          started_at: Time.now, log_path: log_path, dry_run: false,
          request_id: request_id, dispatch_token: dispatch_token, timeout_sec: timeout_sec,
          # Process.spawn(pgroup: true) creates a group led by this exact PID.
          # Persist it before any shutdown race can make getpgid unavailable.
          pgid: pid
        }
        pid
      end

      # R-02: enforce per-child wall-clock timeouts. Called once per
      # dispatcher tick. For every live (non-dry-run) child whose
      # resolved timeout is positive and whose elapsed wall-clock exceeds
      # it: send SIGTERM to its process group on the first breach, then
      # SIGKILL once `kill_grace_sec` has elapsed without the child
      # exiting. Returns an Array<TimeoutAction> describing the signals
      # sent so the dispatcher can emit `:child_timeout` telemetry. The
      # actual ChildExit (with the signal-derived exit status) surfaces
      # on a later `reap_all` once the process dies.
      def enforce_timeouts(now: Time.now)
        actions = []
        @running.each do |pid, entry|
          next if entry[:dry_run]

          timeout_sec = entry[:timeout_sec].to_i
          next unless timeout_sec.positive?

          elapsed = now - entry[:started_at]
          next if elapsed <= timeout_sec

          if entry[:terminating_at].nil?
            pgid = pgid_for(pid)
            safe_kill(:TERM, -pgid) if pgid
            entry[:terminating_at] = now
            actions << timeout_action(pid, entry, :term, elapsed)
          elsif !entry[:killed] && (now - entry[:terminating_at]) >= @kill_grace_sec
            pgid = pgid_for(pid)
            safe_kill(:KILL, -pgid) if pgid
            entry[:killed] = true
            actions << timeout_action(pid, entry, :kill, elapsed)
          end
        end
        actions
      end

      # Reap every child that has exited since the last call. Returns an
      # Array<ChildExit> for the dispatcher to feed into the
      # concurrency controller. Empty array when nothing has completed.
      def reap_all(now: Time.now)
        completed = @forced_completions.shift(@forced_completions.length)
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

          completed << child_exit(pid, status, entry, now)
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
            started_at: entry[:started_at], finished_at: now, json_envelope: nil,
            request_id: entry[:request_id], dispatch_token: entry[:dispatch_token]
          )
        end
        completed.each { |c| @running.delete(c.pid) }
        completed
      end

      # Snapshot and terminate every tracked child's verified process tree,
      # wait up to `grace_sec`, then SIGKILL survivors. Used by the dispatcher's
      # shutdown path. A reaped direct-child exit is returned only after both
      # its captured tree and original process group are proven gone. If that
      # proof is unavailable, the exit is deliberately withheld so the
      # scheduler's existing durable claim remains fenced for restart recovery.
      def terminate_all(grace_sec: 600)
        completed = []
        return completed if @running.empty?

        completed.concat(reap_dry_run)
        return completed if @running.empty?

        targets = capture_shutdown_targets
        pending = []
        signal_shutdown_targets(:TERM, targets)

        drain_shutdown(
          targets: targets,
          pending: pending,
          completed: completed,
          deadline: Time.now + grace_sec
        )
        return completed if shutdown_drained?(pending)

        signal_shutdown_targets(:KILL, targets, require_identity: true)
        drain_shutdown(
          targets: targets,
          pending: pending,
          completed: completed,
          deadline: Time.now + Hive::ProcessKill::KILL_GRACE_SECONDS
        )

        completed
      end

      def in_flight_pids
        @running.keys
      end

      def in_flight_count
        @running.size
      end

      # Terminate and await one exact child process group. Used when a spawn
      # succeeded but its durable PID/start-time/PGID fence could not be
      # persisted; releasing the claim before the child is gone would allow a
      # second generation to overlap it.
      def terminate_child(pid, grace_sec: 2)
        entry = @running[pid]
        return false unless entry && !entry[:dry_run]

        pgid = pgid_for(pid)
        safe_kill(:TERM, -pgid) if pgid
        status = wait_for_child(pid, grace_sec)
        unless status
          pgid = pgid_for(pid)
          safe_kill(:KILL, -pgid) if pgid
          status = wait_for_child(pid, 1)
        end
        return false unless status

        @running.delete(pid)
        @forced_completions << child_exit(pid, status, entry, Time.now)
        true
      end

      # Capture the same PID-reuse and process-group fence persisted by the
      # architecture scheduler immediately after spawn.
      def process_identity(pid)
        return nil unless pid.is_a?(Integer) && pid > 1

        start_time = Hive::Lock.process_start_time(pid)
        pgid = Process.getpgid(pid)
        return nil if start_time.to_s.empty? || pgid <= 1

        { process_start_time: start_time.to_s, pgid: pgid }
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      private

      def wait_for_child(pid, seconds)
        deadline = Time.now + seconds
        loop do
          waited_pid, status = Process.wait2(pid, Process::WNOHANG)
          return status if waited_pid
          return nil if Time.now >= deadline

          sleep 0.02
        end
      rescue Errno::ECHILD
        nil
      end

      def child_exit(pid, status, entry, now)
        ChildExit.new(
          pid: pid, exit_code: status.exitstatus,
          project: entry[:project], slug: entry[:slug], stage: entry[:stage],
          command: entry[:command], state_file_path: entry[:state_file_path],
          started_at: entry[:started_at], finished_at: now,
          json_envelope: completion_envelope(entry),
          request_id: entry[:request_id], dispatch_token: entry[:dispatch_token]
        )
      end

      def parse_command(command_string)
        Shellwords.split(command_string)
      end

      # The hive verb is argv[1] (argv[0] is the hive binary). Returns
      # "" when the command has no verb so `timeout_for_verb` falls back
      # to the default.
      def argv_verb(argv)
        argv[1].to_s
      end

      # Look up a child's process-group id. Returns nil when the process
      # group is already gone (ESRCH) so the caller's `if pgid` guard
      # short-circuits the kill — signaling `-pid` after ESRCH could hit a
      # recycled process group on a long-running host (#249).
      def pgid_for(pid)
        Process.getpgid(pid)
      rescue Errno::ESRCH
        nil
      end

      def timeout_action(pid, entry, action, elapsed)
        TimeoutAction.new(
          pid: pid, project: entry[:project], slug: entry[:slug],
          stage: entry[:stage], command: entry[:command],
          action: action, elapsed_sec: elapsed.to_i,
          timeout_sec: entry[:timeout_sec].to_i
        )
      end

      def capture_shutdown_targets
        @running.each_with_object({}) do |(pid, entry), captured|
          next if entry[:dry_run]

          snapshot = Hive::ProcessKill.process_tree_snapshot(pid)
          confirmed = snapshot && Hive::ProcessKill.confirm_process_tree_snapshot(pid, snapshot)
          tree = if confirmed &&
                    confirmed.size == snapshot.size &&
                    confirmed.any? { |target| target.fetch(:pid) == pid }
            confirmed
          end
          captured[pid] = {
            pgid: entry[:pgid] || pgid_for(pid),
            tree: tree
          }
        end
      end

      def signal_shutdown_targets(signal, targets, require_identity: false)
        targets.each_value do |target|
          tree = target[:tree]
          Hive::ProcessKill.signal_captured_processes(
            signal.to_s, tree, require_identity: require_identity
          ) if tree

          pgid = target[:pgid]
          safe_kill(signal, -pgid) if pgid && process_group_alive?(pgid)
        end
      end

      def drain_shutdown(targets:, pending:, completed:, deadline:)
        loop do
          pending.concat(reap_all)
          releasable, held = pending.partition do |entry|
            shutdown_exit_safe?(entry, targets.fetch(entry.pid, nil))
          end
          completed.concat(releasable)
          pending.replace(held)

          break if shutdown_drained?(pending) || Time.now >= deadline

          sleep 0.1
        end
      end

      def shutdown_drained?(pending)
        @running.empty? && pending.empty?
      end

      def shutdown_exit_safe?(_entry, target)
        return false unless target && target[:tree]
        return false if target[:tree].any? { |process| Hive::ProcessKill.captured_process_alive?(process) }

        pgid = target[:pgid]
        pgid && !process_group_alive?(pgid)
      end

      def process_group_alive?(pgid)
        Process.kill(0, -pgid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def log_path_for(project:, slug:, log_state_path:)
        return @log_dir_for_task.call(project, slug) if @log_dir_for_task

        # The dispatcher supplies Hive's durable XDG state directory so
        # captures neither depend on a quota-limited tmpdir nor dirty the
        # project's tracked hive-state worktree. Standalone callers without
        # that context retain the historical tmpdir fallback.
        if log_state_path
          base = File.join(log_state_path, "logs", "daemon-children", project.to_s, slug.to_s)
          return File.join(base, "daemon-run.log")
        end

        base = File.join(Dir.tmpdir, "hive-daemon-logs", project.to_s, slug.to_s)
        ts = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
        File.join(base, "daemon-run-#{ts}-#{Process.pid}.log")
      end

      # Bytes to read from the END of the child log when scanning for
      # the JSON envelope. The envelope is the last line of stdout per
      # `wiki/cli.md`'s `--json` contract; 64 KB is enormously generous
      # for a single JSON document but bounded against a runaway child
      # that wrote gigabytes of prose. PR-40 follow-up review C1.
      ENVELOPE_TAIL_BYTES = 64 * 1024

      def completion_envelope(entry)
        token = entry[:dispatch_token]
        result_path = token && (token[:result_path] || token["result_path"])
        return parse_envelope(entry[:log_path]) unless result_path

        parse_result_file(result_path)
      ensure
        FileUtils.rm_f(result_path) if result_path
      end

      def parse_result_file(path)
        return nil unless File.file?(path)

        payload = JSON.parse(File.binread(path))
        payload.is_a?(Hash) ? payload : nil
      rescue JSON::ParserError, EncodingError, SystemCallError, IOError
        nil
      end

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
