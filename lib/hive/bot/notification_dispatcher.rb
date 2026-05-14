require "time"
require "hive/config"
require "hive/bot/notification_builders"

module Hive
  module Bot
    class NotificationDispatcher
      def initialize(telegram:, logger:, bot_config:,
                     daemon_enabled: nil, now: -> { Time.now })
        @telegram = telegram
        @logger = logger
        @bot_config = bot_config
        @daemon_enabled = daemon_enabled
        @now = now
        @seen = {}
        @recent_dispatches = {}
      end

      def process_rows(rows)
        prune_seen!
        rows.each { |row| process_row(row) }
      end

      def record_dispatch(project:, slug:)
        @recent_dispatches[[ project, slug ]] = @now.call
      end

      private

      def process_row(row)
        return if suppress_ready_action?(row)
        return if recently_dispatched?(row)

        notification = NotificationBuilders.build(row)
        return unless notification

        fingerprint = NotificationBuilders.fingerprint(row)
        if @seen.key?(fingerprint)
          @logger.event(:notification_skipped_dedupe, project: row.project,
                                                       slug: row.slug,
                                                       marker: row.marker)
          return
        end

        chat_ids.each do |chat_id|
          @telegram.send_message(chat_id: chat_id, text: notification.text,
                                 reply_markup: notification.keyboard)
        end
        @seen[fingerprint] = @now.call
        @logger.event(:notification_sent, project: row.project, slug: row.slug,
                                          marker: row.marker, action: row.action)
      end

      def suppress_ready_action?(row)
        return false unless NotificationBuilders::READY_ACTIONS.include?(row.action)

        daemon_enabled_for?(row.project)
      end

      def daemon_enabled_for?(project)
        return @daemon_enabled.call(project) if @daemon_enabled

        entry = Hive::Config.find_project(project)
        return false unless entry

        Hive::Config.load(entry["path"]).dig("daemon", "enabled") == true
      rescue Hive::ConfigError
        false
      end

      def recently_dispatched?(row)
        dispatched_at = @recent_dispatches[[ row.project, row.slug ]]
        return false unless dispatched_at

        (@now.call - dispatched_at) < dedupe_window
      end

      def prune_seen!
        cutoff = @now.call - dedupe_window
        @seen.delete_if { |_fingerprint, seen_at| seen_at < cutoff }
        @recent_dispatches.delete_if { |_key, seen_at| seen_at < cutoff }
      end

      def chat_ids
        Array(@bot_config.fetch("chat_id_allowlist"))
      end

      def dedupe_window
        @bot_config.fetch("notification_dedupe_window_sec", 300)
      end
    end
  end
end
