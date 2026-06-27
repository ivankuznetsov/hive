require "date"
require "json"
require "optparse"
require "hive/bot/logger"
require "hive/bot/notification_builders"
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

      SCHEMA = "hive-answer-digest".freeze

      # `hive status --json` came back unusable. Distinct from a ConfigError
      # (bad invocation) and an internal crash so a --json agent can tell a
      # transient upstream failure (retry) from a misconfiguration (fix). Stays
      # a generic-exit Error subclass so the exit code (1) and the
      # `assert_raises(Hive::Error)` contract are unchanged.
      class StatusUnavailableError < Hive::Error; end

      # The closed vocabulary of suppression reasons. `nil` is a real send;
      # "empty" is nothing waiting; "dry_run" is a previewed-but-unsent digest.
      # `sent` is derived from this, so the illegal `sent:true, reason:"empty"`
      # state is unrepresentable.
      REASONS = [ nil, "empty", "dry_run" ].freeze

      Result = Data.define(:date, :message, :button_count, :chat_id, :reason, :dry_run, :count, :tasks) do
        def initialize(date:, message:, button_count:, chat_id:, reason:, dry_run:, count:, tasks:)
          unless REASONS.include?(reason)
            raise ArgumentError, "unknown answer-digest reason #{reason.inspect} (expected one of #{REASONS.inspect})"
          end
          # A real send (reason nil) resolved a chat; an unsent result resolved
          # none — encode that here instead of leaving both representable.
          if reason.nil? && (chat_id.nil? || chat_id.to_s.empty?)
            raise ArgumentError, "a sent answer-digest result requires a chat_id"
          end
          if !reason.nil? && !chat_id.nil?
            raise ArgumentError,
                  "an unsent answer-digest result (reason=#{reason.inspect}) must not carry a chat_id"
          end

          super
        end

        # Fully derived from `reason`: a real send is the only outcome with no
        # suppression reason.
        def sent = reason.nil?
      end

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
                   Result.new(date: date, message: "", button_count: 0, chat_id: nil,
                              reason: "empty", dry_run: @dry_run, count: 0, tasks: [])
        else
                   deliver_waiting_digest(waiting, cfg, date)
        end
        emit(result)
        result
      rescue Hive::Error => e
        emit_error_envelope(e) if @json
        raise
      rescue StandardError => e
        # A non-Hive::Error (e.g. a Faraday transport fault) would otherwise
        # escape a manual `--json` run as a raw backtrace with no envelope. The
        # daemon only reads the exit code, so re-raise to preserve it; the
        # agent parsing stdout still gets a structured error.
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
          raise StatusUnavailableError, "hive status unavailable: #{message.empty? ? 'unknown error' : message}"
        end

        Hive::Bot::WaitingRows.select(fetch_result.rows, daemon_enabled: daemon_enabled_resolver,
                                                         logger: @logger)
      end

      def deliver_waiting_digest(rows, cfg, date)
        visible = rows.first(QUEUE_DISPLAY_CAP)
        text = render_digest(rows, visible)
        buttons = visible.filter_map { |row| Hive::Bot::WaitingRows.button_for(row, logger: @logger) }
        keyboard = buttons.map { |button| [ button ] }
        tasks = rows.map { |row| task_descriptor(row) }

        if @dry_run
          return Result.new(date: date, message: text, button_count: buttons.size,
                            chat_id: nil, reason: "dry_run", dry_run: true, count: rows.size, tasks: tasks)
        end

        chat_id = Hive::Digest::Sender.resolve_chat_id(cfg)
        token = Hive::Config.telegram_bot_token!
        telegram = @telegram_factory.call(token: token, logger: logger(cfg))
        telegram.send_message(chat_id: chat_id, text: text, reply_markup: keyboard)
        Result.new(date: date, message: text, button_count: buttons.size,
                   chat_id: chat_id, reason: nil, dry_run: false, count: rows.size, tasks: tasks)
      end

      # Compact machine-readable descriptor for one waiting task so a --json
      # agent can learn how many and which tasks wait — the JSON `count`
      # reports the true total (not the 10-button display cap) and `tasks`
      # lists every waiting row, even on a real send where `message` is null.
      def task_descriptor(row)
        {
          "project" => (row.project if row.respond_to?(:project)),
          "slug" => (row.slug if row.respond_to?(:slug)),
          "id" => (row.id if row.respond_to?(:id)),
          "title" => Hive::Bot::NotificationBuilders.display_title(row),
          "stage" => (row.stage.to_s if row.respond_to?(:stage)),
          "pr" => Hive::Pr.number(row.respond_to?(:pr_url) ? row.pr_url : nil)
        }
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
          "schema" => SCHEMA,
          # Sourced from the single SCHEMA_VERSIONS registry so the emitted
          # version can't drift from the published schema.
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
          "ok" => true,
          "date" => result.date.iso8601,
          "sent" => result.sent,
          "reason" => result.reason,
          "dry_run" => result.dry_run,
          "chat_id" => result.chat_id,
          # The number of inline buttons actually attached (capped at
          # QUEUE_DISPLAY_CAP); `count` is the true waiting total.
          "button_count" => result.button_count,
          "count" => result.count,
          "tasks" => result.tasks,
          "message" => @dry_run ? result.message : nil
        }
      end

      def emit_error_envelope(error)
        @output.puts JSON.generate(
          "schema" => SCHEMA,
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
          "ok" => false,
          "error_class" => error.class.name.split("::").last,
          "error_kind" => error_kind_for(error),
          "exit_code" => error.respond_to?(:exit_code) ? error.exit_code : Hive::ExitCodes::GENERIC,
          "message" => error.message
        )
      end

      def error_kind_for(error)
        return "config" if error.is_a?(Hive::ConfigError)
        return "status_unavailable" if error.is_a?(StatusUnavailableError)

        "internal"
      end

      def daemon_enabled_resolver
        cache = {}
        lambda do |row|
          path = answer_digest_row_project_path(row)
          next false if path.to_s.empty?

          cache.fetch(path) { cache[path] = Hive::Config.load(path).dig("daemon", "enabled") == true }
        rescue Hive::ConfigError => e
          # Match the supervisor's /waiting twin: a broken project config must
          # not be invisible from the digest path. Logs only when a logger was
          # injected (nil in the bare CLI selection phase).
          @logger&.event(:poll_failure, source: "answer_digest_daemon_check",
                                         project: (row.project if row.respond_to?(:project)),
                                         error_class: e.class.name, message: e.message)
          false
        end
      end

      # Mirror Supervisor#waiting_row_project_path so /waiting and the digest
      # resolve the same project path: prefer the row's own `project_path`, and
      # fall back to the registered project's configured path when the snapshot
      # row lacks it. Without the fallback a project_path-less plan_waiting row
      # the bot would hide could leak into the digest.
      def answer_digest_row_project_path(row)
        path = row.project_path if row.respond_to?(:project_path)
        path = path.to_s
        return path unless path.empty?

        entry = Hive::Config.find_project(row.project) if row.respond_to?(:project)
        entry && entry["path"]
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
