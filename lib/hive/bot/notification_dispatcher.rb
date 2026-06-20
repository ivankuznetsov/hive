require "time"
require "hive/config"
require "hive/bot/alert_store"
require "hive/bot/notification_builders"
require "hive/bot/title_formatter"

module Hive
  module Bot
    class NotificationDispatcher
      # ready_to_X notifications are gated by daemon_enabled per project:
      #
      #   daemon ON  → suppress (the daemon itself dispatches the stage transition;
      #                a Telegram ping would be redundant noise)
      #   daemon OFF → fire ONE proactive alert per (project, slug, stage)
      #                fingerprint; persistent dedupe prevents repeats.
      #                The operator approves/rejects from the alert keyboard.
      #
      # This restores the original daemon-aware behaviour after a too-aggressive
      # blanket-suppression fix (see eval s3 noise test, which now models a
      # daemon-enabled project so the contract still holds).
      def initialize(telegram:, logger:, bot_config:,
                     daemon_enabled: nil, now: -> { Time.now },
                     alert_store: nil, conversation_store: nil)
        @telegram = telegram
        @logger = logger
        @bot_config = bot_config
        @daemon_enabled = daemon_enabled
        @now = now
        @alert_store = alert_store || AlertStore.new(path: bot_config["alert_state_file"], logger: logger)
        # Optional: when present, an active answer conversation for a slug
        # suppresses that slug's proactive "questions waiting" push (the
        # operator is already answering). nil = no suppression (older
        # wiring / tests that don't inject it).
        @conversation_store = conversation_store
      end

      def process_rows(rows)
        current = current_notifications(rows)
        if @alert_store.fresh_install?
          immediate, seedable = current.partition do |_fingerprint, payload|
            immediate_on_fresh_install?(payload.fetch(:row))
          end.map(&:to_h)
          seed_silently(seedable)
          @alert_store.mark_seeded!
          process_current(immediate)
          return
        end
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
          next if suppress_daemon_plan_pause?(row)
          next if suppress_active_conversation?(row)

          notification = NotificationBuilders.build(row, logger: @logger)
          next unless notification

          fingerprint = NotificationBuilders.fingerprint(row)
          out[fingerprint] ||= { row: row, notification: notification }
        end
      end

      # Suppress the proactive "X is waiting for your input" push for a
      # slug the operator is actively answering. Only `needs_input` rows
      # (brainstorm Q&A / review triage) are gated — error / recovery
      # alerts always fire even mid-answer. The first alert still fires
      # (no conversation exists until the operator taps "Answer in chat"),
      # and an abandoned conversation stops suppressing once it TTL-expires.
      # Scoped to (project, slug) so two projects sharing a slug can't
      # cross-suppress. Logs the skip, matching `:notification_skipped_*`,
      # so "why didn't I get the alert?" has an audit trail.
      def suppress_active_conversation?(row)
        return false unless @conversation_store
        return false unless row.action == Hive::Schemas::TaskActionKind::NEEDS_INPUT
        return false unless @conversation_store.active_for_slug?(row.slug, project: row.project)

        @logger.event(:notification_skipped_active_conversation,
                      project: row.project, slug: row.slug, marker: row.marker)
        true
      end

      # Suppress the proactive "questions waiting" push for a 3-plan
      # approval pause when the daemon is enabled for the project. A
      # 3-plan `waiting` marker is a plan-draft/approval pause, NOT a
      # brainstorm question — and the daemon's `PlanApproval` auto-approves
      # it (flips `waiting` → `complete`, dispatches `hive develop`) within
      # a tick. Without this gate the bot's status poll races the daemon
      # and pings the operator about a pause the daemon is about to resolve
      # on its own — an unactionable alert (the operator can't approve a
      # plan from the brainstorm `/answer` flow anyway). Mirrors
      # `suppress_ready_action?`'s daemon-aware gating.
      def suppress_daemon_plan_pause?(row)
        return false unless row.action == "needs_input"
        return false unless coding_workflow?(row)
        return false unless row.stage.to_s == "3-plan" && row.marker.to_s == "waiting" # coding-scoped: daemon auto-approval only applies to coding plan pauses
        return false unless daemon_enabled_for?(row.project)

        @logger.event(:notification_skipped_daemon_plan_pause,
                      project: row.project, slug: row.slug, marker: row.marker)
        true
      end

      def coding_workflow?(row)
        return true unless row.respond_to?(:workflow)

        workflow = row.workflow.to_s
        workflow.empty? || workflow == "coding"
      end

      def immediate_on_fresh_install?(row)
        NotificationBuilders.legacy_stage_dirs?(row)
      end

      # On a fresh AlertStore (no prior persistent state), pretend every
      # current notification has already been delivered to every chat in the
      # allowlist. This populates the store with a baseline so subsequent
      # ticks only alert on deltas — operators don't see a thunderstorm of
      # ⚠ alerts on day 1 for failures that pre-date the bot's deployment.
      def seed_silently(current)
        return if current.empty?

        chats = chat_ids
        current.each do |fingerprint, payload|
          @alert_store.add(fingerprint, payload.fetch(:row), @now.call, delivered_to: chats)
        end
        @logger.event(:fresh_install_seeded, fingerprint_count: current.size)
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
                                 reply_markup: notification.keyboard,
                                 parse_mode: notification.parse_mode)
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
        lines[0] = "⚠ Still stuck (#{reminder_window_label}) — \"#{NotificationBuilders.display_title(row)}\" — " \
                   "#{TitleFormatter.stage_label(row.stage, logger: @logger)}"
        NotificationBuilders::Notification.new(text: lines.join("\n"), keyboard: notification.keyboard)
      end

      def recovered_message(row)
        NotificationBuilders::Notification.new(
          text: "✅ Recovered: \"#{NotificationBuilders.display_title(row)}\" — " \
                "#{TitleFormatter.stage_label(row.stage, logger: @logger)}",
          keyboard: nil
        )
      end

      def reminder_window_label
        seconds = recovery_reminder_window.to_i
        hours = seconds / 3600
        remainder_seconds = seconds - (hours * 3600)
        minutes = (remainder_seconds / 60.0).round
        if hours >= 1 && minutes.positive?
          "#{hours} h #{minutes} min"
        elsif hours >= 1
          "#{hours} h"
        else
          "#{(seconds / 60.0).round} min"
        end
      end

      # Suppress proactive ready_to_X notifications only when the project's
      # daemon is enabled (the daemon will dispatch the stage transition
      # itself; a Telegram ping would duplicate work). With daemon OFF the
      # operator needs the Approve/Reject keyboard to advance the workflow,
      # so the alert fires.
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
