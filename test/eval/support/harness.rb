require "time"
require "tmpdir"
require "hive/config"
require "hive/bot/conversation_store"
require "hive/bot/notification_dispatcher"
require "hive/bot/router"
require "hive/bot/status_watcher"
require "hive/bot/supervisor"
require_relative "programmable_status_watcher"

module Hive
  module Eval
    class Harness
      attr_reader :telegram, :logger, :status_watcher, :child_supervisor, :supervisor, :router

      def initialize(bot_config: nil, telegram: nil, logger: nil, status_watcher: nil,
                     child_supervisor: nil, notification_dispatcher: nil,
                     conversation_store: nil, now: Time.utc(2026, 5, 24, 8, 0, 0))
        @now = now
        @bot_config = default_bot_config.merge(bot_config || {})
        @telegram = telegram || Hive::Eval::FakeTelegram.new(now: -> { current_time })
        @logger = logger || Hive::Eval::CapturingLogger.new(now: -> { current_time })
        @status_watcher = status_watcher || Hive::Eval::ProgrammableStatusWatcher.new
        @child_supervisor = child_supervisor ||
          Hive::Eval::FakeChildSupervisor.new(logger: @logger, now: -> { current_time })
        @conversation_store = conversation_store ||
          Hive::Bot::ConversationStore.new(ttl_sec: @bot_config.fetch("conversation_ttl_sec"))
        @router = Hive::Bot::Router.new(
          bot_config: @bot_config,
          logger: @logger,
          conversation_store: @conversation_store
        )
        @notification_dispatcher = notification_dispatcher ||
          Hive::Bot::NotificationDispatcher.new(
            telegram: @telegram,
            logger: @logger,
            bot_config: @bot_config,
            daemon_enabled: ->(_project) { false },
            now: -> { current_time }
          )
        @supervisor = Hive::Bot::Supervisor.new(
          config: @bot_config,
          token: "eval-token",
          logger: @logger,
          telegram: @telegram,
          status_watcher: @status_watcher,
          notification_dispatcher: @notification_dispatcher,
          router: @router,
          child_supervisor: @child_supervisor,
          conversation_store: @conversation_store,
          dry_run: false
        )
      end

      def sent
        @telegram.sent
      end

      def last_sent
        sent.last
      end

      def process(update)
        intent = classify(update)
        before = sent.length
        @supervisor.process_update(update)
        annotate_new_messages(before, source: :handler, intent: intent)
      end

      def when_user_sends(text, update_id: next_update_id, reply_to_text: nil)
        update = @telegram.inject_update(text: text, update_id: update_id,
                                         reply_to_text: reply_to_text)
        process(update)
        update
      end

      def when_user_taps(callback_data, update_id: next_update_id, message_id: nil)
        update = @telegram.tap_button(callback_data: callback_data, update_id: update_id,
                                      message_id: message_id)
        process(update)
        update
      end

      def status_tick!(rows:)
        before = sent.length
        @status_watcher.queue(rows: rows) if @status_watcher.respond_to?(:queue)
        result = @supervisor.status_tick
        annotate_status_messages(before, rows)
        result
      end

      def reap_children
        before = sent.length
        @supervisor.reap_children
        annotate_new_messages(before, source: :child)
      end

      def advance(seconds)
        @now += seconds
      end

      def current_time
        @now
      end

      private

      def default_bot_config
        {
          "chat_id_allowlist" => [ Hive::Eval::FakeTelegram::DEFAULT_CHAT_ID ],
          "conversation_ttl_sec" => 3600,
          "long_poll_timeout_sec" => 25,
          "poll_interval_sec" => 30,
          "notification_dedupe_window_sec" => 300,
          "shutdown_grace_sec" => 1,
          "last_seen_state_file" => nil,
          "clear_retry_grace_sec" => 1,
          "codex_budget_usd" => 1,
          "codex_timeout_sec" => 120,
          "log_file" => File.join(Dir.tmpdir, "hive-eval-bot.log"),
          "log_max_bytes" => 10_485_760,
          "log_max_files" => 5
        }
      end

      def classify(update)
        @router.classify(update)
      rescue StandardError
        :unknown
      end

      def next_update_id
        @next_update_id ||= 0
        @next_update_id += 1
      end

      def annotate_new_messages(before, source:, intent: nil)
        sent[before..]&.each do |message|
          message.source = source
          message.intent = intent if intent
        end
      end

      def annotate_status_messages(before, rows)
        new_messages = sent[before..] || []
        unmatched_rows = rows.dup
        new_messages.each do |message|
          row_idx = unmatched_rows.index do |row|
            notification = Hive::Bot::NotificationBuilders.build(row)
            notification && notification.text == message.text
          end
          row = row_idx ? unmatched_rows.delete_at(row_idx) : nil
          message.source = :status_row
          message.row = row
        end
      end
    end
  end
end
