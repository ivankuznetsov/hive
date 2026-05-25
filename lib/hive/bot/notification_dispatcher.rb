require "time"
require "hive/config"
require "hive/bot/alert_store"
require "hive/bot/notification_builders"
require "hive/bot/title_formatter"

module Hive
  module Bot
    class NotificationDispatcher
      def initialize(telegram:, logger:, bot_config:,
                     daemon_enabled: nil, now: -> { Time.now },
                     alert_store: nil)
        @telegram = telegram
        @logger = logger
        @bot_config = bot_config
        @daemon_enabled = daemon_enabled
        @now = now
        @alert_store = alert_store || AlertStore.new(path: bot_config["alert_state_file"], logger: logger)
      end

      def process_rows(rows)
        current = current_notifications(rows)
        process_recoveries(current)
        process_current(current)
      end

      def reset_task(project:, slug:, stage: nil, marker: nil, match_attr: nil)
        @alert_store.remove_matching(project: project, slug: slug, stage: stage,
                                     marker: marker, match_attr: match_attr)
      end

      private

      def current_notifications(rows)
        Array(rows).each_with_object({}) do |row, out|
          next if suppress_ready_action?(row)

          notification = NotificationBuilders.build(row)
          next unless notification

          fingerprint = NotificationBuilders.fingerprint(row)
          out[fingerprint] ||= { row: row, notification: notification }
        end
      end

      def process_recoveries(current)
        @alert_store.each_fingerprint do |fingerprint|
          next if current.key?(fingerprint)

          entry = @alert_store.entry(fingerprint)
          row = entry&.row
          next if row.nil?

          if NotificationBuilders.recovery?(row)
            if current_recovery_for_same_row?(current, row)
              @alert_store.remove(fingerprint)
              next
            end
            next if backoff_active?(entry)

            unless absence_passed_grace?(entry, fingerprint)
              next
            end

            if send_notification(recovered_message(row)).any?
              @alert_store.remove(fingerprint)
              log_notification_sent(row, recovered: true)
            else
              @alert_store.record_send_failure(fingerprint, @now.call)
            end
          else
            @alert_store.remove(fingerprint)
          end
        end
      end

      def absence_passed_grace?(entry, fingerprint)
        if entry.absent_since.nil?
          @alert_store.mark_absent(fingerprint, @now.call)
          return false
        end

        (@now.call - entry.absent_since) >= recovery_grace_seconds
      end

      def recovery_grace_seconds
        @bot_config.fetch("recovery_grace_sec", 60).to_i
      end

      def process_current(current)
        current.each do |fingerprint, payload|
          row = payload.fetch(:row)
          entry = @alert_store.entry(fingerprint)
          @alert_store.mark_present(fingerprint) if entry && entry.absent_since
          entry = @alert_store.entry(fingerprint) if entry
          if entry.nil?
            delivered = send_notification(payload.fetch(:notification))
            if delivered.any?
              @alert_store.add(fingerprint, row, @now.call, delivered_to: delivered)
              log_notification_sent(row)
            else
              # Persist the entry with no delivered chats so the backoff
              # window applies to subsequent ticks during the outage.
              @alert_store.add(fingerprint, row, @now.call, delivered_to: [])
              @alert_store.record_send_failure(fingerprint, @now.call)
            end
          elsif backoff_active?(entry)
            @logger.event(:notification_skipped_backoff, project: row.project, slug: row.slug,
                                                          marker: row.marker,
                                                          consecutive_failures: entry.consecutive_failures.to_i)
          elsif (pending = pending_chat_ids(entry)).any?
            newly_delivered = send_notification(payload.fetch(:notification), to: pending)
            if newly_delivered.any?
              @alert_store.record_delivery(fingerprint, newly_delivered)
              log_notification_sent(row)
            else
              @alert_store.record_send_failure(fingerprint, @now.call)
            end
          elsif reminder_due?(entry, row)
            if send_notification(reminder_notification(row)).any?
              @alert_store.mark_reminded(fingerprint, @now.call)
              @alert_store.record_send_success(fingerprint)
              log_notification_sent(row, reminder: true)
            else
              @alert_store.record_send_failure(fingerprint, @now.call)
            end
          else
            @logger.event(:notification_skipped_dedupe, project: row.project,
                                                         slug: row.slug,
                                                         marker: row.marker)
          end
        end
      end

      def backoff_active?(entry)
        next_attempt = entry.next_attempt_after
        return false unless next_attempt

        @now.call < next_attempt
      end

      def pending_chat_ids(entry)
        delivered = Array(entry.delivered_to).map(&:to_s)
        chat_ids.reject { |c| delivered.include?(c.to_s) }
      end

      def send_notification(notification, to: nil)
        targets = filter_chats(to)
        succeeded = []
        targets.each do |chat_id|
          @telegram.send_message(chat_id: chat_id, text: notification.text,
                                 reply_markup: notification.keyboard)
          succeeded << chat_id
        rescue StandardError => e
          @logger.event(:send_failure, chat_id: chat_id, error_class: e.class.name, message: e.message)
        end

        succeeded
      end

      def filter_chats(to)
        return chat_ids if to.nil?

        allow = Array(to).map(&:to_s)
        chat_ids.select { |c| allow.include?(c.to_s) }
      end

      def log_notification_sent(row, reminder: false, recovered: false)
        @logger.event(:notification_sent, project: row.project, slug: row.slug,
                                          marker: row.marker, action: row.action,
                                          reminder: reminder, recovered: recovered)
      end

      def current_recovery_for_same_row?(current, stored_row)
        current.values.any? do |payload|
          row = payload.fetch(:row)
          NotificationBuilders.recovery?(row) && recovery_identity(row) == recovery_identity(stored_row)
        end
      end

      def recovery_identity(row)
        [ row.project.to_s, row.slug.to_s, row.stage.to_s ]
      end

      def reminder_due?(entry, row)
        return false unless NotificationBuilders.recovery?(row)
        return false unless entry.first_seen_at
        return false if entry.reminded_at

        @now.call - entry.first_seen_at >= recovery_reminder_window
      end

      def reminder_notification(row)
        notification = NotificationBuilders.recovery(row)
        lines = notification.text.lines(chomp: true)
        unless lines[0].to_s.start_with?("⚠ ")
          raise "reminder_notification expected NotificationBuilders.recovery to emit a leading \"⚠ \" headline; " \
                "got #{lines[0].inspect} — update reminder_notification together with the recovery builder."
        end
        lines[0] = "⚠ Still stuck (#{reminder_window_label}) — \"#{TitleFormatter.title_from_slug(row.slug)}\" — " \
                   "#{TitleFormatter.stage_label(row.stage, logger: @logger)}"
        NotificationBuilders::Notification.new(text: lines.join("\n"), keyboard: notification.keyboard)
      end

      def recovered_message(row)
        NotificationBuilders::Notification.new(
          text: "✅ Recovered: \"#{TitleFormatter.title_from_slug(row.slug)}\" — " \
                "#{TitleFormatter.stage_label(row.stage, logger: @logger)}",
          keyboard: nil
        )
      end

      def reminder_window_label
        seconds = recovery_reminder_window.to_i
        hours = seconds / 3600
        return "#{hours} h" if hours >= 1 && seconds % 3600 == 0

        minutes = (seconds / 60.0).round
        "#{minutes} min"
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
      rescue Hive::ConfigError => e
        @logger.event(:poll_failure, source: "daemon_check", project: project,
                                      error_class: e.class.name, message: e.message)
        false
      end

      def chat_ids
        Array(@bot_config.fetch("chat_id_allowlist"))
      end

      def recovery_reminder_window
        @bot_config.fetch("recovery_reminder_window_sec", 28_800)
      end
    end
  end
end
