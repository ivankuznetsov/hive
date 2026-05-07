require "fileutils"
require "json"
require "time"
require "yaml"
require "hive/config"
require "hive/lock"
require "hive/daemon/dispatcher"
require "hive/daemon/concurrency_controller"
require "hive/daemon/child_supervisor"
require "hive/daemon/status_consumer"
require "hive/daemon/pr_merge_watcher"
require "hive/daemon/logger"

module Hive
  module Commands
    # `hive daemon SUBCOMMAND` — operator-facing CLI for the Hive
    # daemon (ADR-024).
    #
    # Subcommands:
    #   start [--detach] [--dry-run]   Run the dispatcher loop.
    #   stop                           Send SIGTERM to the running daemon.
    #   status [--json]                Show running / not-running + uptime.
    #   reload                         Send SIGHUP to reload config.
    #   tail                           Stream daemon.log (tail -F semantics).
    class Daemon
      VALID_SUBCOMMANDS = %w[start stop status reload tail].freeze

      def initialize(subcommand, detach: false, dry_run: false, json: false,
                     hive_home: Hive::Config.hive_home)
        @subcommand = subcommand
        @detach = detach
        @dry_run = dry_run
        @json = json
        @hive_home = hive_home
      end

      def call
        unless VALID_SUBCOMMANDS.include?(@subcommand)
          raise Hive::InvalidTaskPath,
                "hive daemon: unknown subcommand #{@subcommand.inspect} " \
                "(expected: #{VALID_SUBCOMMANDS.join(', ')})"
        end

        case @subcommand
        when "start"  then start_daemon
        when "stop"   then stop_daemon
        when "status" then status_daemon
        when "reload" then reload_daemon
        when "tail"   then tail_daemon
        end
      end

      def pid_file
        @pid_file ||= File.join(@hive_home, ".daemon.pid")
      end

      def log_file
        @log_file ||= File.join(@hive_home, "logs", "daemon.log")
      end

      private

      def start_daemon
        FileUtils.mkdir_p(@hive_home)
        FileUtils.mkdir_p(File.dirname(log_file))

        # Single-instance check: if a live daemon already owns the PID
        # file, refuse with TEMPFAIL.
        if (existing = read_live_pid)
          raise Hive::ConcurrentRunError.new(
            "hive daemon already running (pid #{existing})",
            holder: { pid: existing }, lock_path: pid_file
          )
        end

        # Stale PID file from a prior crash → safe to remove.
        File.delete(pid_file) if File.exist?(pid_file)

        if @detach
          Process.daemon(true, true)
        end

        # PR-40 follow-up review C5: refuse to start if we can't capture
        # our own start_time. Without it the PID-reuse defense degrades
        # to "trust everything" silently — and `hive daemon stop` could
        # eventually SIGKILL an unrelated process that happened to land
        # on a reused PID. Better to fail loudly at startup so the
        # operator can fix their environment (typically: missing /proc,
        # stripped `ps`, or a containerised host with both unavailable).
        own_start_time = Hive::Lock.send(:process_start_time, Process.pid)
        if own_start_time.nil?
          raise Hive::Error,
                "hive daemon: cannot read process start time " \
                "(neither /proc/#{Process.pid}/stat nor `ps -o lstart=` worked); " \
                "PID-reuse defense would be disabled. Refusing to start. " \
                "If this is a containerised host, ensure /proc is mounted or `ps` is on PATH."
        end

        # Write the PID file as YAML with process_start_time so `stop`
        # can detect PID reuse before sending TERM/KILL to a random
        # process that happens to have the same PID. PR-40 review P2 #3.
        File.write(pid_file, pid_file_payload(Process.pid, own_start_time).to_yaml)

        # Load the daemon block from ~/Dev/hive/config.yml so operator
        # overrides (max_concurrent_runs, poll_interval_sec, log paths,
        # etc.) actually take effect. PR-40 review P1 #2: this used to
        # call merge_defaults({}) which discarded the global config.
        daemon_cfg = Hive::Config.load_global_daemon
        config = { "daemon" => daemon_cfg }

        controller = Hive::Daemon::ConcurrencyController.new(
          max_concurrent_runs: daemon_cfg.fetch("max_concurrent_runs"),
          max_concurrent_per_project: daemon_cfg.fetch("max_concurrent_per_project"),
          max_runs_per_day_per_project: daemon_cfg.fetch("max_runs_per_day_per_project")
        )
        supervisor = Hive::Daemon::ChildSupervisor.new(dry_run: @dry_run)
        status_consumer = Hive::Daemon::StatusConsumer.new
        logger = Hive::Daemon::Logger.new(
          path: daemon_cfg.fetch("log_file", log_file),
          max_bytes: daemon_cfg.fetch("log_max_bytes"),
          max_files: daemon_cfg.fetch("log_max_files")
        )
        merge_watcher = Hive::Daemon::PrMergeWatcher.new(
          poll_interval_sec: daemon_cfg.fetch("pr_merge_poll_interval_sec")
        )

        dispatcher = Hive::Daemon::Dispatcher.new(
          config: config, controller: controller, supervisor: supervisor,
          status_consumer: status_consumer, logger: logger,
          merge_watcher: merge_watcher, dry_run: @dry_run
        )

        begin
          dispatcher.run_forever
        ensure
          # PR-40 follow-up review C2: parse via read_pid_file_payload
          # so the cleanup matches the YAML-payload format the daemon
          # writes. The earlier `File.read.strip.to_i` returned 0 against
          # the YAML doc, so the file leaked on every clean shutdown.
          payload = begin
            read_pid_file_payload
          rescue StandardError
            nil
          end
          File.delete(pid_file) if payload && payload["pid"] == Process.pid && File.exist?(pid_file)
        end
      end

      def stop_daemon
        unless File.exist?(pid_file)
          if @json
            puts JSON.generate(stop_envelope(running: false, was_running: false))
          else
            warn "hive: daemon not running (no PID file at #{pid_file})"
          end
          return
        end

        payload = read_pid_file_payload
        pid = payload && payload["pid"]
        if pid.nil? || pid <= 0
          warn "hive: daemon PID file at #{pid_file} is malformed; removing"
          File.delete(pid_file)
          return
        end

        unless pid_alive?(pid)
          # Stale PID file
          File.delete(pid_file)
          if @json
            puts JSON.generate(stop_envelope(running: false, was_running: false, stale_pid: pid))
          else
            warn "hive: daemon PID #{pid} is not alive; removed stale #{pid_file}"
          end
          return
        end

        # PR-40 review P2 #3 + follow-up C5: PID-reuse safety. Use the
        # tri-state `pid_ownership` outcome to decide whether to send
        # signals at all:
        #   :verified / :legacy → safe to TERM
        #   :reused             → refuse, remove stale PID file
        #   :unverified         → refuse (we cannot prove this PID is
        #                         actually our daemon; bystander safety)
        ownership = pid_ownership(payload, pid)
        case ownership
        when :reused
          File.delete(pid_file)
          if @json
            puts JSON.generate(stop_envelope(running: false, was_running: false,
                                             stale_pid: pid, reason: "pid_reused"))
          else
            warn "hive: PID #{pid} appears reused (start_time mismatch); " \
                 "refusing to signal. Removed stale #{pid_file}."
          end
          return
        when :unverified
          if @json
            puts JSON.generate(stop_envelope(running: false, was_running: false,
                                             stale_pid: pid, reason: "unverified"))
          else
            warn "hive: cannot verify PID #{pid} is the hive daemon " \
                 "(no /proc, no `ps`?); refusing to signal. " \
                 "Manually confirm and `kill #{pid}` after, then `rm #{pid_file}`."
          end
          return
        end

        send_signal_safely(pid, :TERM)
        # Wait up to shutdown_grace_sec for the daemon to exit
        deadline = Time.now + 600
        while pid_alive?(pid) && Time.now < deadline
          sleep 0.5
        end

        if pid_alive?(pid)
          # Escalate to KILL — but re-verify ownership before the
          # second signal, in case the original daemon JUST died in
          # the grace window and the OS handed the PID off.
          ownership_now = pid_ownership(payload, pid)
          if ownership_now == :reused || ownership_now == :unverified
            warn "hive: PID #{pid} ownership flipped to #{ownership_now} mid-stop; aborting KILL signal"
          else
            send_signal_safely(pid, :KILL)
          end
          File.delete(pid_file) if File.exist?(pid_file)
        end

        if @json
          puts JSON.generate(stop_envelope(running: false, was_running: true))
        else
          puts "hive: daemon stopped (pid #{pid})"
        end
      end

      def status_daemon
        running = false
        pid = nil
        uptime_sec = nil

        if File.exist?(pid_file)
          payload = read_pid_file_payload
          pid = payload && payload["pid"]
          if pid && pid > 0 && pid_alive?(pid) && pid_owned_by_us?(payload, pid)
            running = true
            stat = File.stat(pid_file)
            uptime_sec = (Time.now - stat.mtime).to_i
          end
        end

        if @json
          puts JSON.generate(
            "schema" => "hive-daemon-status",
            "schema_version" => 1,
            "ok" => true,
            "running" => running,
            "pid" => running ? pid : nil,
            "uptime_sec" => uptime_sec,
            "pid_file" => pid_file,
            "log_file" => log_file
          )
        elsif running
          puts "hive daemon: running (pid #{pid}, uptime #{uptime_sec}s)"
        else
          puts "hive daemon: not running"
        end
        # Exit code: 0 for running, 1 for not running (per plan U8)
        raise Hive::Error, "daemon not running" unless running
      end

      def reload_daemon
        unless File.exist?(pid_file)
          warn "hive: daemon not running (no PID file at #{pid_file})"
          raise Hive::Error, "daemon not running"
        end

        payload = read_pid_file_payload
        pid = payload && payload["pid"]
        unless pid && pid > 0 && pid_alive?(pid)
          warn "hive: daemon PID #{pid} is not alive; remove #{pid_file} and restart"
          raise Hive::Error, "daemon PID is dead"
        end

        # PR-40 review P2 #3 + follow-up C5: ownership tri-state.
        ownership = pid_ownership(payload, pid)
        case ownership
        when :reused
          warn "hive: PID #{pid} appears reused (start_time mismatch); refusing HUP"
          raise Hive::Error, "daemon PID is reused"
        when :unverified
          warn "hive: cannot verify PID #{pid} is the hive daemon; refusing HUP"
          raise Hive::Error, "daemon PID is unverified"
        end

        send_signal_safely(pid, :HUP)
        puts "hive: daemon reload requested (pid #{pid})"
      end

      def tail_daemon
        unless File.exist?(log_file)
          warn "hive: daemon log file not found at #{log_file}"
          raise Hive::Error, "daemon log file missing"
        end

        # Self-implemented tail -F semantics so we don't depend on a
        # `tail` binary being on PATH in containerised environments.
        File.open(log_file, "r") do |f|
          f.seek(0, IO::SEEK_END)
          loop do
            chunk = f.read
            if chunk && !chunk.empty?
              $stdout.write(chunk)
              $stdout.flush
            else
              sleep 0.5
            end
          end
        end
      rescue Interrupt
        # Ctrl-C → exit cleanly
      end

      def read_live_pid
        return nil unless File.exist?(pid_file)

        payload = read_pid_file_payload
        pid = payload && payload["pid"]
        return nil unless pid && pid > 0
        return nil unless pid_alive?(pid)
        # PR-40 review P2 #3: a `pid_alive?` PID owned by an unrelated
        # process (after PID reuse) must NOT be treated as our daemon.
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

      # Verify the live process at `pid` is the daemon we wrote to the
      # PID file. Returns one of three symbols:
      #
      #   :verified   — recorded and live start_time both present AND match.
      #                 Safe to send signals.
      #   :reused     — both present but DIFFER. The OS handed `pid` to
      #                 a different process; refuse signals.
      #   :unverified — at least one side is nil. Cannot prove it's the
      #                 daemon. Refuse signals to avoid hitting bystanders.
      #
      # PR-40 follow-up review C5 — split from the prior "true on either
      # nil" boolean which silently degraded to TRUST in stripped
      # containers. The bare-integer back-compat path (legacy PID files)
      # produces a :legacy outcome callers may treat as :verified at
      # their discretion.
      def pid_ownership(payload, pid)
        return :unverified if payload.nil?
        return :legacy     if payload["_legacy"]

        recorded = payload["process_start_time"]
        live = Hive::Lock.send(:process_start_time, pid)
        return :unverified if recorded.nil? || live.nil?

        recorded == live ? :verified : :reused
      end

      # Back-compat predicate; true only when the daemon is genuinely
      # confirmed to own the PID. Legacy files get :verified-class
      # treatment to match the prior behavior for hand-written PID
      # files used in tests.
      def pid_owned_by_us?(payload, pid)
        ownership = pid_ownership(payload, pid)
        ownership == :verified || ownership == :legacy
      end

      def read_pid_file_payload
        return nil unless File.exist?(pid_file)

        raw = File.read(pid_file)
        # New YAML format
        parsed = YAML.safe_load(raw, permitted_classes: [ Time ]) rescue nil
        return parsed if parsed.is_a?(Hash) && parsed["pid"]

        # Back-compat: a bare-integer PID file (older daemon versions OR
        # a hand-written PID for testing). Mark it with `_legacy` so the
        # ownership check can distinguish "intentional bare-int" from
        # "process_start_time silently nil at write time on a stripped
        # container" — the latter is the C5 attack surface we just
        # closed at write-time but the read-time check still needs to
        # tell the two cases apart.
        if raw.strip =~ /\A\d+\z/
          return { "pid" => raw.strip.to_i, "process_start_time" => nil, "_legacy" => true }
        end

        nil
      end

      def pid_file_payload(pid, start_time = nil)
        # PR-40 follow-up review C5: callers in start_daemon now read
        # the start_time once and pass it explicitly so the failure
        # mode is observable at start (refuse to start) rather than
        # silently dropping a `nil` into the PID file.
        start_time ||= Hive::Lock.send(:process_start_time, pid)
        {
          "pid" => pid,
          "process_start_time" => start_time,
          "started_at" => Time.now.utc.iso8601
        }
      end

      def send_signal_safely(pid, signal)
        Process.kill(signal, pid)
      rescue Errno::ESRCH
        # Already gone
      rescue Errno::EPERM
        warn "hive: insufficient permissions to signal pid #{pid}"
      end

      def stop_envelope(running:, was_running:, stale_pid: nil, reason: nil)
        {
          "schema" => "hive-daemon-stop",
          "schema_version" => 1,
          "ok" => true,
          "running" => running,
          "was_running" => was_running,
          "stale_pid" => stale_pid,
          "reason" => reason
        }.compact
      end
    end
  end
end
