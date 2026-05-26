require "fileutils"
require "time"
require "yaml"
require "hive/config"
require "hive/paths"
require "hive/lock"
require "hive/pid_file"
require "hive/babysitter/dispatcher"
require "hive/babysitter/logger"

module Hive
  module Commands
    class Babysit
      include Hive::PidFile

      VALID_SUBCOMMANDS = %w[start stop status reload tail].freeze

      def initialize(subcommand = nil, target = nil, detach: false, dry_run: false,
                     once: false, all: false, hive_home: Hive::Paths.state_home)
        @subcommand = subcommand
        @target = target
        @detach = detach
        @dry_run = dry_run
        @once = once
        @all = all
        @hive_home = hive_home
      end

      def call
        return run_once if @once

        unless VALID_SUBCOMMANDS.include?(@subcommand)
          raise Hive::InvalidTaskPath,
                "hive babysit: unknown or missing subcommand #{@subcommand.inspect} " \
                "(expected: #{VALID_SUBCOMMANDS.join(', ')}, or --once PROJECT)"
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
        @pid_file ||= File.join(@hive_home, ".babysitter.pid")
      end

      def log_file
        @log_file ||= File.join(@hive_home, "logs", "babysitter.log")
      end

      private

      def start_daemon
        FileUtils.mkdir_p(@hive_home)
        FileUtils.mkdir_p(File.dirname(log_file))

        if (existing = read_live_pid)
          raise Hive::ConcurrentRunError.new(
            "hive babysitter already running (pid #{existing})",
            holder: { pid: existing },
            lock_path: pid_file
          )
        end
        File.delete(pid_file) if File.exist?(pid_file)

        Process.daemon(true, true) if @detach

        own_start_time = Hive::Lock.send(:process_start_time, Process.pid)
        if own_start_time.nil?
          raise Hive::Error,
                "hive babysitter: cannot read process start time " \
                "(neither /proc/#{Process.pid}/stat nor `ps -o lstart=` worked); " \
                "PID-reuse defense would be disabled. Refusing to start."
        end

        File.write(pid_file, pid_file_payload(Process.pid, own_start_time).to_yaml)
        dispatcher = build_dispatcher
        begin
          dispatcher.run_forever
        ensure
          payload = begin
            read_pid_file_payload
          rescue StandardError
            nil
          end
          File.delete(pid_file) if payload && payload["pid"] == Process.pid && File.exist?(pid_file)
        end
      end

      def run_once
        project_name = resolve_once_project_name
        dispatcher = build_dispatcher(project_name: project_name, max_ticks: 1)
        dispatcher.run_forever
      end

      def resolve_once_project_name
        if @all
          raise Hive::InvalidTaskPath, "hive babysit --once: do not also pass PROJECT when using --all" if present?(@target)

          return nil
        end

        unless present?(@target)
          raise Hive::InvalidTaskPath, "hive babysit --once: missing PROJECT (or pass --all)"
        end

        entry = Hive::Config.find_project(@target)
        unless entry
          raise Hive::InvalidTaskPath,
                "hive babysit --once: unknown project #{@target.inspect} " \
                "(see `hive status` for the registered set)"
        end
        entry["name"]
      end

      def present?(value)
        !value.nil? && !value.to_s.strip.empty?
      end

      def build_dispatcher(project_name: nil, max_ticks: nil)
        daemon_cfg = Hive::Config.load_global_daemon
        logger = Hive::Babysitter::Logger.new(
          path: log_file,
          max_bytes: daemon_cfg.fetch("log_max_bytes"),
          max_files: daemon_cfg.fetch("log_max_files")
        )
        Hive::Babysitter::Dispatcher.new(
          logger: logger,
          dry_run: @dry_run,
          project_name: project_name,
          max_ticks: max_ticks
        )
      end

      def stop_daemon
        unless File.exist?(pid_file)
          warn "hive: babysitter not running (no PID file at #{pid_file})"
          return
        end

        payload = read_pid_file_payload
        pid = payload && payload["pid"]
        if pid.nil? || pid <= 0
          File.delete(pid_file)
          warn "hive: babysitter PID file at #{pid_file} is malformed; removing"
          return
        end

        unless pid_alive?(pid)
          File.delete(pid_file)
          warn "hive: babysitter PID #{pid} is not alive; removed stale #{pid_file}"
          return
        end

        case pid_ownership(payload, pid)
        when :reused
          File.delete(pid_file)
          warn "hive: PID #{pid} appears reused (start_time mismatch); refusing to signal. Removed stale #{pid_file}."
          return
        when :unverified
          warn "hive: cannot verify PID #{pid} is the hive babysitter; refusing to signal. Manually confirm and clean #{pid_file}."
          return
        end

        send_signal_safely(pid, :TERM)
        deadline = Time.now + 600
        while pid_alive?(pid) && Time.now < deadline
          sleep 0.5
        end
        if pid_alive?(pid)
          ownership_now = pid_ownership(payload, pid)
          send_signal_safely(pid, :KILL) unless %i[reused unverified].include?(ownership_now)
          File.delete(pid_file) if File.exist?(pid_file)
        end
        puts "hive babysitter: stopped (pid #{pid})"
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
            uptime_sec = (Time.now - File.stat(pid_file).mtime).to_i
          end
        end

        if running
          puts "hive babysitter: running (pid #{pid}, uptime #{uptime_sec}s)"
        else
          puts "hive babysitter: not running"
          raise Hive::Error, "babysitter not running"
        end
      end

      def reload_daemon
        unless File.exist?(pid_file)
          raise Hive::Error, "babysitter not running (no PID file at #{pid_file})"
        end

        payload = read_pid_file_payload
        pid = payload && payload["pid"]
        unless pid && pid > 0 && pid_alive?(pid)
          raise Hive::Error, "babysitter PID #{pid.inspect} is not alive; remove #{pid_file} and restart"
        end

        case pid_ownership(payload, pid)
        when :reused
          raise Hive::Error, "PID #{pid} appears reused (start_time mismatch); refusing HUP"
        when :unverified
          raise Hive::Error, "cannot verify PID #{pid} is the hive babysitter; refusing HUP"
        end

        send_signal_safely(pid, :HUP)
        puts "hive babysitter: reload requested (pid #{pid})"
      end

      def tail_daemon
        unless File.exist?(log_file)
          warn "hive: babysitter log file not found at #{log_file}"
          raise Hive::Error, "babysitter log file missing"
        end

        File.open(log_file, "r") do |file|
          file.seek(0, IO::SEEK_END)
          loop do
            chunk = file.read
            if chunk && !chunk.empty?
              $stdout.write(chunk)
              $stdout.flush
            else
              sleep 0.5
            end
          end
        end
      rescue Interrupt
        nil
      end
    end
  end
end
