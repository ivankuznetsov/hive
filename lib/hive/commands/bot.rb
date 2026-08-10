require "fileutils"
require "json"
require "time"
require "yaml"
require "hive/config"
require "hive/env_file"
require "hive/lock"
require "hive/bot/supervisor"
require "hive/bot/logger"
require "hive/pid_file"
require "hive/paths"
require "hive/update_check/state"
require "hive/commands/service_installer/result_presenter"
require "hive/recovery/migration"

module Hive
  module Commands
    class Bot
      include Hive::Commands::ServiceInstaller::ResultPresenter

      VALID_SUBCOMMANDS = %w[start stop status reload tail install].freeze
      JSON_USAGE_ERROR_SCHEMA = "hive-bot-status".freeze

      def self.json_usage_error_payload(error:, error_kind:)
        Hive::Schemas::ErrorEnvelope.build(
          schema: JSON_USAGE_ERROR_SCHEMA,
          error: error,
          error_kind: error_kind
        )
      end

      def initialize(subcommand, detach: nil, foreground: false, dry_run: false, json: false,
                     force: false, hive_home: Hive::Paths.state_home)
        @subcommand = subcommand
        @foreground = foreground || detach == false
        @dry_run = dry_run
        @json = json
        @force = force
        @hive_home = hive_home
      end

      def call
        if @subcommand.nil?
          raise_usage_error(
            "hive bot: missing SUBCOMMAND (expected: #{VALID_SUBCOMMANDS.join(', ')})",
            error_kind: "missing_subcommand"
          )
        end
        unless VALID_SUBCOMMANDS.include?(@subcommand)
          raise_usage_error(
            "hive bot: unknown subcommand #{@subcommand.inspect} " \
            "(expected: #{VALID_SUBCOMMANDS.join(', ')})",
            error_kind: "unknown_subcommand"
          )
        end

        case @subcommand
        when "start" then start_bot
        when "stop" then stop_bot
        when "status" then status_bot
        when "reload" then reload_bot
        when "tail" then tail_bot
        when "install" then install_bot
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

      def raise_usage_error(message, error_kind:)
        error = Hive::InvalidTaskPath.new(message)
        emit_usage_error(error, error_kind: error_kind) if @json
        raise error
      end

      def emit_usage_error(error, error_kind:)
        puts_json(self.class.json_usage_error_payload(
          error: error,
          error_kind: error_kind
        ))
      rescue Errno::EPIPE, JSON::GeneratorError
        nil
      end

      def start_bot
        # Load ~/.config/hive/.env (if present) so operators don't have to
        # paste HIVE_TELEGRAM_BOT_TOKEN into shell startup. Existing env vars
        # take precedence — a manual `export` still overrides the file.
        Hive::EnvFile.load!
        FileUtils.mkdir_p(@hive_home)
        FileUtils.mkdir_p(File.dirname(pid_file))
        FileUtils.mkdir_p(File.dirname(log_file))
        Hive::Recovery::Migration.ensure!(state_home: @hive_home)

        lock_file = File.open(pid_file, File::RDWR | File::CREAT, 0o644)
        unless lock_file.flock(File::LOCK_EX | File::LOCK_NB)
          payload = pid_file_payload
          existing_pid = payload["pid"]
          lock_file.close
          raise Hive::ConcurrentRunError.new("hive bot already running (pid #{existing_pid})",
                                             holder: { pid: existing_pid }, lock_path: pid_file)
        end

        Process.daemon(true, true) unless @foreground
        lock_file.rewind
        lock_file.truncate(0)
        lock_file.write({ "pid" => Process.pid, "started_at" => Time.now.utc.iso8601 }.to_yaml)
        lock_file.flush

        supervisor = Hive::Bot::Supervisor.new(
          config: bot_config,
          token: Hive::Config.telegram_bot_token!,
          dry_run: @dry_run,
          # Same shared state file the daemon writes — makes the cross-process
          # contract visible at the call site (Supervisor would default to this
          # anyway).
          update_state: Hive::UpdateCheck::State.new
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
        uptime =
          if running
            started_at_raw = pid_file_payload["started_at"]
            if started_at_raw
              begin
                (Time.now - Time.parse(started_at_raw.to_s)).to_i
              rescue ArgumentError
                nil
              end
            end
          end
        service_state = probe_service_state
        payload = {
          "schema" => "hive-bot-status",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-bot-status"),
          "ok" => true,
          "running" => running,
          "pid" => pid,
          "uptime_sec" => uptime,
          "pid_file" => pid_file,
          "log_file" => log_file,
          "service_installed" => service_state["service_installed"],
          "service_enabled" => service_state["service_enabled"],
          "unit_path" => service_state["unit_path"]
        }
        if @json
          puts_json(payload)
        else
          puts(running ? "hive bot: running (pid #{pid}, uptime #{uptime}s)" : "hive bot: not running")
        end
        raise Hive::Error, "bot not running" if !running && !@json
      end

      # Read-only autostart-state snapshot for the status envelope. A status
      # probe must never take down the running/pid reporting that precedes
      # it, so any failure degrades the three service fields to null (the
      # status schema marks them required-but-nullable) instead of raising
      # out of the whole command.
      def probe_service_state
        require "hive/commands/bot/service_installer"
        Hive::Commands::Bot::ServiceInstaller.new.service_state
      rescue StandardError
        { "service_installed" => nil, "service_enabled" => nil, "unit_path" => nil }
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
        nil
      end

      # `hive bot install [--force]` — (re)write the platform-native unit
      # file (systemd-user on Linux, launchd plist on macOS) and enable
      # autostart. Mirrors `hive daemon install` exactly: default refuses to
      # touch an existing unit so operator hand-edits are preserved; --force
      # overwrites and saves the prior content to `<path>.bak-<timestamp>`.
      #
      # With --json: emits a `hive-bot-install.v1` envelope on every
      # outcome. Drift without --force exits 64 (USAGE — retry with
      # --force). Service-manager failure exits 70 (SOFTWARE). Success
      # outcomes (`written` / `upgraded` / `unchanged` / `unsupported`)
      # exit 0.
      def install_bot
        require "hive/commands/bot/service_installer"
        installer = Hive::Commands::Bot::ServiceInstaller.new(binary_path: current_binary_path)
        perform_service_install(installer)
      end

      def service_install_label = "bot"
      def service_install_schema = "hive-bot-install"
      def service_install_drift_error = Hive::BotInstallDriftError
      def service_install_failure_error = Hive::BotInstallFailed

      def current_binary_path
        require "hive/invoked_binary"
        Hive::InvokedBinary.path
      end

      def live_pid
        payload = pid_file_payload
        pid = payload["pid"]
        return nil unless pid && pid_alive?(pid)

        pid
      end

      def pid_file_payload
        Hive::PidFile.read(pid_file)
      rescue Psych::Exception => e
        warn "hive: bot PID file at #{pid_file} is corrupted (#{e.class}: #{e.message}); refusing to assume bot state"
        raise Hive::Error, "bot pid file at #{pid_file} is corrupted"
      end

      def pid_alive?(pid)
        Hive::PidFile.alive?(pid)
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
