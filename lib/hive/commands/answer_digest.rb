require "date"
require "json"
require "optparse"
require "hive/bot/logger"
require "hive/bot/status_watcher"
require "hive/bot/telegram"
require "hive/bot/title_formatter"
require "hive/bot/waiting_rows"
require "hive/config"
require "hive/digest/sender"
require "hive/digest/window"
require "hive/env_file"
require "hive/pr"

module Hive
  module Commands
    class AnswerDigest
      QUEUE_DISPLAY_CAP = 10

      Result = Data.define(:sent, :date, :message, :button_count, :chat_id, :reason, :dry_run)

      def initialize(date: nil, dry_run: false, json: false, output: $stdout, cfg: nil,
                     status_watcher: nil, telegram_factory: nil, env_loader: Hive::EnvFile,
                     config_loader: -> { Hive::Config.load_global_digest_config },
                     logger: nil, now: -> { Time.now })
        @date = date
        @dry_run = dry_run
        @json = json
        @output = output
        @cfg = cfg
        @status_watcher = status_watcher
        @telegram_factory = telegram_factory || method(:build_telegram)
        @env_loader = env_loader
        @config_loader = config_loader
        @logger = logger
        @now = now
      end

      def call(argv = nil)
        parse_argv(argv) if argv
        date = parse_date
        cfg = @cfg || @config_loader.call
        @env_loader.load! unless @dry_run

        waiting = waiting_rows(cfg)
        result = if waiting.empty?
                   Result.new(sent: false, date: date, message: "", button_count: 0, chat_id: nil,
                              reason: "empty", dry_run: @dry_run)
        else
                   deliver_waiting_digest(waiting, cfg, date)
        end
        emit(result)
        result
      rescue Hive::Error => e
        emit_error_envelope(e) if @json
        raise
      end

      private

      def parse_argv(argv)
        parser = OptionParser.new do |opts|
          opts.on("--date DATE") { |value| @date = value }
          opts.on("--dry-run") { @dry_run = true }
          opts.on("--json") { @json = true }
        end
        parser.parse!(Array(argv))
        raise Hive::ConfigError, "hive answer-digest: unexpected arguments: #{argv.join(' ')}" unless argv.empty?
      rescue OptionParser::ParseError => e
        raise Hive::ConfigError, "hive answer-digest: #{e.message}"
      end

      def parse_date
        raw = @date.to_s
        return Hive::Digest::Window.local_today(now: @now.call) if raw.empty?

        unless raw.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          raise Hive::ConfigError, "hive answer-digest: --date must be YYYY-MM-DD; got #{@date.inspect}"
        end

        Hive::Digest::Window.parse_date(raw)
      rescue ArgumentError
        raise Hive::ConfigError, "hive answer-digest: --date must be YYYY-MM-DD; got #{@date.inspect}"
      end

      def waiting_rows(_cfg)
        fetch_result = status_watcher.fetch
        unless fetch_result.ok
          message = fetch_result.respond_to?(:error) ? fetch_result.error.to_s : "unknown error"
          raise Hive::Error, "hive status unavailable: #{message.empty? ? 'unknown error' : message}"
        end

        Hive::Bot::WaitingRows.select(fetch_result.rows, daemon_enabled: daemon_enabled_resolver)
      end

      def deliver_waiting_digest(rows, cfg, date)
        visible = rows.first(QUEUE_DISPLAY_CAP)
        text = render_digest(rows, visible)
        buttons = visible.filter_map { |row| Hive::Bot::WaitingRows.button_for(row) }
        keyboard = buttons.map { |button| [ button ] }

        if @dry_run
          return Result.new(sent: false, date: date, message: text, button_count: buttons.size,
                            chat_id: nil, reason: "dry_run", dry_run: true)
        end

        chat_id = Hive::Digest::Sender.resolve_chat_id(cfg)
        token = Hive::Config.telegram_bot_token!
        telegram = @telegram_factory.call(token: token, logger: logger(cfg))
        telegram.send_message(chat_id: chat_id, text: text, reply_markup: keyboard)
        Result.new(sent: true, date: date, message: text, button_count: buttons.size,
                   chat_id: chat_id, reason: nil, dry_run: false)
      end

      def render_digest(rows, visible)
        lines = [ "⏳ Waiting on you (#{rows.size})" ]
        visible.each do |row|
          lines << "#{Hive::Bot::NotificationBuilders.display_title(row)} — #{pr_label(row)} — " \
                   "#{Hive::Bot::TitleFormatter.stage_label(row.stage, logger: @logger)}"
        end
        if rows.size > QUEUE_DISPLAY_CAP
          lines << "+ #{rows.size - QUEUE_DISPLAY_CAP} more tasks — open on a laptop for the full list."
        end
        lines.join("\n")
      end

      def pr_label(row)
        Hive::Pr.number(row.respond_to?(:pr_url) ? row.pr_url : nil) || "—"
      end

      def emit(result)
        if @json
          @output.puts JSON.generate(json_payload(result))
        elsif @dry_run && !result.message.empty?
          @output.puts result.message
          @output.puts "Buttons: #{result.button_count}"
        elsif result.sent
          @output.puts "hive answer-digest: sent #{result.button_count} waiting task#{result.button_count == 1 ? '' : 's'}"
        end
      end

      def json_payload(result)
        {
          "ok" => true,
          "date" => result.date.iso8601,
          "sent" => result.sent,
          "reason" => result.reason,
          "dry_run" => result.dry_run,
          "chat_id" => result.chat_id,
          "button_count" => result.button_count,
          "message" => @dry_run ? result.message : nil
        }
      end

      def emit_error_envelope(error)
        @output.puts JSON.generate(
          "ok" => false,
          "error_class" => error.class.name.split("::").last,
          "error_kind" => error.is_a?(Hive::ConfigError) ? "config" : "internal",
          "exit_code" => error.respond_to?(:exit_code) ? error.exit_code : Hive::ExitCodes::GENERIC,
          "message" => error.message
        )
      end

      def daemon_enabled_resolver
        cache = {}
        lambda do |row|
          path = row.project_path if row.respond_to?(:project_path)
          path = path.to_s
          next false if path.empty?

          cache.fetch(path) { cache[path] = Hive::Config.load(path).dig("daemon", "enabled") == true }
        rescue Hive::ConfigError
          false
        end
      end

      def status_watcher
        @status_watcher ||= Hive::Bot::StatusWatcher.new(logger: @logger)
      end

      def build_telegram(token:, logger:)
        Hive::Bot::Telegram.new(token: token, logger: logger)
      end

      def logger(cfg)
        @logger ||= Hive::Bot::Logger.new(path: cfg.dig("bot", "log_file"))
      end
    end
  end
end
