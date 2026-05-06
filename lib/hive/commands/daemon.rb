require "fileutils"
require "json"
require "time"
require "hive/config"
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

        File.write(pid_file, Process.pid.to_s)

        config = Hive::Config.send(:merge_defaults, {})
        daemon_cfg = config["daemon"] || {}

        controller = Hive::Daemon::ConcurrencyController.new(
          max_concurrent_runs: daemon_cfg.fetch("max_concurrent_runs", 3),
          max_concurrent_per_project: daemon_cfg.fetch("max_concurrent_per_project", 1),
          max_runs_per_day_per_project: daemon_cfg.fetch("max_runs_per_day_per_project", 50)
        )
        supervisor = Hive::Daemon::ChildSupervisor.new(dry_run: @dry_run)
        status_consumer = Hive::Daemon::StatusConsumer.new
        logger = Hive::Daemon::Logger.new(
          path: daemon_cfg.fetch("log_file", log_file),
          max_bytes: daemon_cfg.fetch("log_max_bytes", 10_485_760),
          max_files: daemon_cfg.fetch("log_max_files", 5)
        )
        merge_watcher = Hive::Daemon::PrMergeWatcher.new(
          poll_interval_sec: daemon_cfg.fetch("pr_merge_poll_interval_sec", 300)
        )

        dispatcher = Hive::Daemon::Dispatcher.new(
          config: config, controller: controller, supervisor: supervisor,
          status_consumer: status_consumer, logger: logger,
          merge_watcher: merge_watcher, dry_run: @dry_run
        )

        begin
          dispatcher.run_forever
        ensure
          File.delete(pid_file) if File.exist?(pid_file) && File.read(pid_file).strip.to_i == Process.pid
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

        pid = File.read(pid_file).strip.to_i
        if pid <= 0
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

        send_signal_safely(pid, :TERM)
        # Wait up to shutdown_grace_sec for the daemon to exit
        deadline = Time.now + 600
        while pid_alive?(pid) && Time.now < deadline
          sleep 0.5
        end

        if pid_alive?(pid)
          # Escalate to KILL
          send_signal_safely(pid, :KILL)
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
          pid = File.read(pid_file).strip.to_i
          if pid > 0 && pid_alive?(pid)
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

        pid = File.read(pid_file).strip.to_i
        unless pid > 0 && pid_alive?(pid)
          warn "hive: daemon PID #{pid} is not alive; remove #{pid_file} and restart"
          raise Hive::Error, "daemon PID is dead"
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

        pid = File.read(pid_file).strip.to_i
        return nil unless pid > 0
        return nil unless pid_alive?(pid)

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

      def send_signal_safely(pid, signal)
        Process.kill(signal, pid)
      rescue Errno::ESRCH
        # Already gone
      rescue Errno::EPERM
        warn "hive: insufficient permissions to signal pid #{pid}"
      end

      def stop_envelope(running:, was_running:, stale_pid: nil)
        {
          "schema" => "hive-daemon-stop",
          "schema_version" => 1,
          "ok" => true,
          "running" => running,
          "was_running" => was_running,
          "stale_pid" => stale_pid
        }.compact
      end
    end
  end
end
