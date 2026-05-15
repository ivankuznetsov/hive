require "fileutils"
require "json"
require "time"
require "yaml"
require "hive/config"
require "hive/lock"
require "hive/bot/supervisor"
require "hive/bot/logger"

module Hive
  module Commands
    class Bot
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
                "hive bot: unknown subcommand #{@subcommand.inspect} " \
                "(expected: #{VALID_SUBCOMMANDS.join(', ')})"
        end

        case @subcommand
        when "start" then start_bot
        when "stop" then stop_bot
        when "status" then status_bot
        when "reload" then reload_bot
        when "tail" then tail_bot
        end
      end

      def bot_config
        @bot_config ||= Hive::Config.load_global_bot(require_runtime: @subcommand == "start")
      end

      def pid_file
        File.expand_path(bot_config.fetch("pid_file", File.join(@hive_home, ".bot.pid")))
      end

      def log_file
        File.expand_path(bot_config.fetch("log_file", File.join(@hive_home, "logs", "bot.log")))
      end

      private

      def start_bot
        FileUtils.mkdir_p(@hive_home)
        FileUtils.mkdir_p(File.dirname(pid_file))
        FileUtils.mkdir_p(File.dirname(log_file))

        lock_file = File.open(pid_file, File::RDWR | File::CREAT, 0o644)
        unless lock_file.flock(File::LOCK_EX | File::LOCK_NB)
          payload = pid_file_payload
          existing_pid = payload["pid"]
          lock_file.close
          raise Hive::ConcurrentRunError.new("hive bot already running (pid #{existing_pid})",
                                             holder: { pid: existing_pid }, lock_path: pid_file)
        end

        Process.daemon(true, true) if @detach
        lock_file.rewind
        lock_file.truncate(0)
        lock_file.write({ "pid" => Process.pid, "started_at" => Time.now.utc.iso8601 }.to_yaml)
        lock_file.flush

        supervisor = Hive::Bot::Supervisor.new(
          config: bot_config,
          token: Hive::Config.telegram_bot_token!,
          dry_run: @dry_run
        )
        supervisor.run_forever
      ensure
        begin
          File.delete(pid_file) if File.exist?(pid_file) && pid_file_payload["pid"] == Process.pid
        rescue StandardError
          nil
        end
        begin
          lock_file&.close
        rescue StandardError
          nil
        end
      end

      def stop_bot
        pid = live_pid
        unless pid
          File.delete(pid_file) if File.exist?(pid_file)
          return puts_json(stop_envelope(running: false, was_running: false)) if @json

          warn "hive: bot not running"
          return
        end

        Process.kill("TERM", pid)
        grace = bot_config.fetch("shutdown_grace_sec", 60)
        deadline = Time.now + grace
        sleep 0.5 while pid_alive?(pid) && Time.now < deadline
        if pid_alive?(pid)
          Process.kill("KILL", pid)
          escalate_deadline = Time.now + 5
          sleep 0.2 while pid_alive?(pid) && Time.now < escalate_deadline
        end
        File.delete(pid_file) if File.exist?(pid_file)
        @json ? puts_json(stop_envelope(running: false, was_running: true)) : puts("hive: bot stopped (pid #{pid})")
      rescue Errno::ESRCH
        File.delete(pid_file) if File.exist?(pid_file)
      end

      def status_bot
        pid = live_pid
        running = !pid.nil?
        uptime = if running
                   started_at_raw = pid_file_payload["started_at"]
                   if started_at_raw
                     begin
                       (Time.now - Time.parse(started_at_raw.to_s)).to_i
                     rescue ArgumentError
                       nil
                     end
                   end
                 end
        payload = {
          "schema" => "hive-bot-status",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-bot-status"),
          "ok" => true,
          "running" => running,
          "pid" => pid,
          "uptime_sec" => uptime,
          "pid_file" => pid_file,
          "log_file" => log_file
        }
        if @json
          puts_json(payload)
        else
          puts(running ? "hive bot: running (pid #{pid}, uptime #{uptime}s)" : "hive bot: not running")
        end
        raise Hive::Error, "bot not running" unless running
      end

      def reload_bot
        pid = live_pid
        unless pid
          payload = reload_envelope(ok: false, reason: "not_running", pid: nil,
                                    message: "bot not running")
          @json ? puts_json(payload) : warn("hive: bot not running")
          raise Hive::Error, "bot not running"
        end

        Process.kill("HUP", pid)
        payload = reload_envelope(ok: true, reason: nil, pid: pid,
                                  message: "bot reload requested (pid #{pid})")
        @json ? puts_json(payload) : puts("hive: bot reload requested (pid #{pid})")
      end

      def tail_bot
        unless File.exist?(log_file)
          warn "hive: bot log file not found at #{log_file}"
          raise Hive::Error, "bot log file missing"
        end

        tail_bin = ENV.fetch("HIVE_TAIL_BIN", "tail")
        Process.exec([ tail_bin, tail_bin ], "-F", log_file)
      rescue Errno::ENOENT
        warn "hive: tail binary not found"
        raise Hive::Error, "tail binary not available"
      rescue Interrupt
        nil
      end

      def live_pid
        payload = pid_file_payload
        pid = payload["pid"]
        return nil unless pid && pid_alive?(pid)

        pid
      end

      def pid_file_payload
        return {} unless File.exist?(pid_file)

        data = YAML.safe_load(File.read(pid_file)) || {}
        data.is_a?(Hash) ? data : {}
      rescue Psych::Exception => e
        warn "hive: bot PID file at #{pid_file} is corrupted (#{e.class}: #{e.message}); refusing to assume bot state"
        raise Hive::Error, "bot pid file at #{pid_file} is corrupted"
      end

      def pid_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def stop_envelope(running:, was_running:)
        {
          "schema" => "hive-bot-stop",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-bot-stop"),
          "ok" => true,
          "running" => running,
          "was_running" => was_running,
          "pid_file" => pid_file
        }
      end

      def reload_envelope(ok:, reason:, pid:, message:)
        {
          "schema" => "hive-bot-reload",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-bot-reload"),
          "ok" => ok,
          "pid" => pid,
          "reason" => reason,
          "message" => message
        }.compact
      end

      def puts_json(payload)
        puts JSON.generate(payload)
      end
    end
  end
end
