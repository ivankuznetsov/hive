require "fileutils"
require "json"
require "time"
require "yaml"
require "hive/config"
require "hive/env_file"
require "hive/lock"
require "hive/bot/supervisor"
require "hive/bot/logger"
require "hive/paths"

module Hive
  module Commands
    class Bot
      VALID_SUBCOMMANDS = %w[start stop status reload tail install].freeze

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

      def start_bot
        # Load ~/.config/hive/.env (if present) so operators don't have to
        # paste HIVE_TELEGRAM_BOT_TOKEN into shell startup. Existing env vars
        # take precedence — a manual `export` still overrides the file.
        Hive::EnvFile.load!
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

        Process.daemon(true, true) unless @foreground
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
        require "hive/commands/bot/service_installer"
        service_state = Hive::Commands::Bot::ServiceInstaller.new.service_state
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
        begin
          result = installer.install!(autostart: true, force: @force)
        rescue Hive::Error
          raise
        rescue StandardError => e
          install_emit_exception_envelope(installer, e) if @json
          raise Hive::BotInstallFailed,
                "bot service install failed: #{e.class}: #{e.message}"
        end
        unless @json
          installer.messages.each { |line| warn "hive: #{line}" }
          emit_install_success_summary(installer, result)
        end
        emit_install_outcome(installer, result)
      end

      # Bare-text positive confirmation on the non-JSON success path so
      # operators can distinguish first-time install / no-op / in-place
      # upgrade at a glance. Mirrors `daemon#emit_install_success_summary`.
      def emit_install_success_summary(installer, result)
        return if @json

        case result
        when :ok, :written
          puts "hive bot: installed unit at #{installer.target_path}"
        when :upgraded
          msg = "hive bot: upgraded unit at #{installer.target_path}"
          msg += " (backup: #{installer.last_backup_path})" if installer.last_backup_path
          puts msg
        when :unchanged
          puts "hive bot: unit already up to date at #{installer.target_path}"
        when :autostart_unavailable
          puts "hive bot: unit written at #{installer.target_path}; autostart not enabled on this host"
        when :unsupported, :drifted, :failed
          # :unsupported is messaged via installer.messages.
          # :drifted / :failed are handled by emit_install_outcome
          # (which raises); no positive summary applies.
        end
      end

      def emit_install_outcome(installer, result)
        outcome_str =
          case result
          when :written then "written"
          when :upgraded then "upgraded"
          when :unchanged then "unchanged"
          # The unit was written but autostart could not be enabled because
          # the host has no supported service manager (Linux without
          # systemd-user). A known-platform limitation, not a software
          # failure, so it reports the `unsupported` success outcome
          # (exit 0); `target_path` still points at the written unit.
          when :autostart_unavailable then "unsupported"
          when :unsupported then "unsupported"
          when :drifted then "drifted"
          when :failed then "failed"
          when :ok then "written"
          end
        success = %w[written upgraded unchanged unsupported].include?(outcome_str)

        if @json
          if success
            puts JSON.generate(install_envelope(installer, outcome: outcome_str))
          else
            install_emit_error_envelope(installer, outcome: outcome_str)
          end
        end

        case result
        when :drifted
          msg = "bot unit at #{installer.target_path} differs from the current template. " \
                "Re-run with `hive bot install --force` to overwrite (a timestamped .bak " \
                "will be saved)."
          raise Hive::BotInstallDriftError, msg
        when :failed
          raise Hive::BotInstallFailed,
                "bot service install reported a failure; see messages above"
        end
      end

      def install_envelope(installer, outcome:)
        restarted = outcome == "upgraded" ? installer.last_restart_invoked : false
        backup_path = outcome == "upgraded" ? installer.last_backup_path : nil
        target = installer.target_path
        {
          "schema" => "hive-bot-install",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-bot-install"),
          "ok" => true,
          "outcome" => outcome,
          "platform" => installer.envelope_platform,
          "target_path" => target,
          "backup_path" => backup_path,
          "restarted" => restarted,
          "messages" => installer.messages.dup
        }
      end

      def install_emit_error_envelope(installer, outcome:)
        error_class = outcome == "drifted" ? "BotInstallDriftError" : "BotInstallFailed"
        exit_code = outcome == "drifted" ? Hive::ExitCodes::USAGE : Hive::ExitCodes::SOFTWARE
        message =
          if outcome == "drifted"
            "bot unit at #{installer.target_path} differs from the current template; retry with --force."
          else
            "bot service install reported a failure; see messages"
          end
        puts JSON.generate(
          "schema" => "hive-bot-install",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-bot-install"),
          "ok" => false,
          "error_class" => error_class,
          "error_kind" => outcome,
          "exit_code" => exit_code,
          "message" => message,
          "outcome" => outcome,
          "platform" => installer.envelope_platform,
          "target_path" => installer.target_path,
          "messages" => installer.messages.dup
        )
      end

      def install_emit_exception_envelope(installer, error)
        puts JSON.generate(
          "schema" => "hive-bot-install",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-bot-install"),
          "ok" => false,
          "error_class" => "BotInstallFailed",
          "error_kind" => "failed",
          "exit_code" => Hive::ExitCodes::SOFTWARE,
          "message" => "bot service install failed: #{error.class}: #{error.message}",
          "outcome" => "failed",
          "platform" => safe_install_platform(installer),
          "target_path" => safe_install_target_path(installer),
          "messages" => safe_install_messages(installer)
        )
      end

      def current_binary_path
        require "hive/invoked_binary"
        Hive::InvokedBinary.path
      end

      def safe_install_platform(installer)
        installer.envelope_platform
      rescue StandardError
        "unsupported"
      end

      def safe_install_target_path(installer)
        installer.target_path
      rescue StandardError
        nil
      end

      def safe_install_messages(installer)
        installer.messages.dup
      rescue StandardError
        []
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
