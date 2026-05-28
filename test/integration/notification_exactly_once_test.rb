require "test_helper"
require "fileutils"
require "tmpdir"
require "hive/bot/notification_dispatcher"
require "hive/bot/notification_builders"
require "hive/bot/status_watcher"
require "hive/bot/alert_store"

# Plan 2026-05-28-002 §7 "UX behavior preservation":
#   After the dual-writer collapses to one (daemon-only), the bot's
#   "next question" message comes from the daemon's notification path
#   — same code as today, just no longer competing with the bot-side
#   reaper. This test pins the exactly-one-notification-per-state-
#   change invariant against the live NotificationDispatcher to make
#   sure the refactor didn't introduce a double-send or a missed-send.
class HiveBotNotificationExactlyOnceTest < Minitest::Test
  include HiveTestHelper

  Row = Hive::Bot::StatusWatcher::Row

  class FakeTelegram
    attr_reader :messages
    def initialize
      @messages = []
    end

    def send_message(chat_id:, text:, reply_markup: nil)
      @messages << { chat_id: chat_id, text: text, reply_markup: reply_markup }
    end
  end

  class StubLogger
    attr_reader :events
    def initialize
      @events = []
    end

    def event(name, **attrs)
      @events << [ name, attrs ]
    end

    def close; end
  end

  def needs_input_row(project: "hive", slug: "s1", stage: "2-brainstorm",
                     marker: "waiting", attrs: { "round" => "1" },
                     state_file_mtime: Time.utc(2026, 5, 28, 18, 0, 0))
    Row.new(
      project: project, slug: slug, stage: stage, marker: marker,
      folder: "/tmp/#{slug}",
      state_file: "/tmp/#{slug}/brainstorm.md",
      state_file_mtime: state_file_mtime,
      action: "needs_input",
      suggested_command: "hive run #{slug}",
      attrs: attrs
    )
  end

  def build_dispatcher(alert_path:)
    telegram = FakeTelegram.new
    logger = StubLogger.new
    bot_cfg = {
      "alert_state_file" => alert_path,
      "chat_id_allowlist" => [ 42 ],
      "recovery_grace_sec" => 60,
      "reminder_interval_sec" => 86_400
    }
    dispatcher = Hive::Bot::NotificationDispatcher.new(
      telegram: telegram, logger: logger, bot_config: bot_cfg,
      daemon_enabled: ->(_project) { true }
    )
    # Fresh-install seeding suppresses initial alerts. Pre-mark the
    # store as seeded so the first tick fires normally — the scenario
    # under test is what happens AFTER the bot has been running.
    dispatcher.instance_variable_get(:@alert_store).mark_seeded!
    [ dispatcher, telegram, logger ]
  end

  def test_round_1_question_fires_exactly_one_notification
    Dir.mktmpdir("hive-notif") do |dir|
      dispatcher, telegram, logger = build_dispatcher(alert_path: File.join(dir, "alerts.json"))
      row = needs_input_row
      dispatcher.process_rows([ row ])

      notifications_sent = logger.events.count { |(n, _)| n == :notification_sent }
      assert_equal 1, notifications_sent,
                   "first sighting of a needs_input/waiting row must fire exactly one notification"
      assert_equal 1, telegram.messages.size

      # Same row, same fingerprint, next tick → must NOT re-fire.
      dispatcher.process_rows([ row ])
      again = logger.events.count { |(n, _)| n == :notification_sent }
      assert_equal 1, again,
                   "the same fingerprint on a subsequent tick must dedupe — no second notification"
    end
  end

  def test_round_2_after_agent_writes_new_questions_fires_exactly_one_more
    Dir.mktmpdir("hive-notif") do |dir|
      dispatcher, telegram, logger = build_dispatcher(alert_path: File.join(dir, "alerts.json"))
      round_1 = needs_input_row(attrs: { "round" => "1" })
      dispatcher.process_rows([ round_1 ])
      assert_equal 1, logger.events.count { |(n, _)| n == :notification_sent },
                   "round 1 fires once"

      # Simulate the agent's `hive run` cycle:
      #   - row transitions to agent_running (no waiting fingerprint visible)
      #   - then back to needs_input/waiting with NEW attrs (round=2)
      # The fingerprint changes because marker attrs include the round.
      agent_running = Row.new(
        project: "hive", slug: "s1", stage: "2-brainstorm", marker: nil,
        folder: "/tmp/s1", state_file: "/tmp/s1/brainstorm.md",
        state_file_mtime: Time.utc(2026, 5, 28, 18, 10, 0),
        action: "agent_running", suggested_command: nil,
        attrs: {}
      )
      dispatcher.process_rows([ agent_running ])

      round_2 = needs_input_row(attrs: { "round" => "2" },
                                state_file_mtime: Time.utc(2026, 5, 28, 18, 13, 9))
      dispatcher.process_rows([ round_2 ])

      total = logger.events.count { |(n, _)| n == :notification_sent }
      assert_equal 2, total,
                   "round 2 (new fingerprint) must fire exactly one ADDITIONAL notification"
      assert_equal 2, telegram.messages.size,
                   "exactly two Telegram sends across the full round-1 → round-2 cycle"
    end
  end

  def test_unchanged_row_across_three_ticks_fires_only_once
    Dir.mktmpdir("hive-notif") do |dir|
      dispatcher, _telegram, logger = build_dispatcher(alert_path: File.join(dir, "alerts.json"))
      row = needs_input_row

      3.times { dispatcher.process_rows([ row ]) }

      sent = logger.events.count { |(n, _)| n == :notification_sent }
      assert_equal 1, sent,
                   "a stable fingerprint across N ticks must produce exactly one notification " \
                   "— no daemon-driven double-send"
    end
  end
end
