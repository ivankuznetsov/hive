require "test_helper"
require "hive/bot/status_watcher"
require "hive/bot/notification_dispatcher"

class HiveBotNotificationDispatcherTest < Minitest::Test
  Row = Hive::Bot::StatusWatcher::Row

  def row(action: "needs_input", marker: "waiting", attrs: {}, slug: "slug-260514-abcd")
    Row.new(
      project: "hive",
      slug: slug,
      stage: "2-brainstorm",
      marker: marker,
      attrs: attrs,
      action: action,
      action_label: "Needs your input",
      folder: "/tmp/#{slug}",
      suggested_command: "hive brainstorm #{slug}"
    )
  end

  def dispatcher(now: Time.utc(2026, 5, 14, 12, 0, 0), daemon_enabled: ->(_project) { false })
    @clock = now
    Hive::Bot::NotificationDispatcher.new(
      telegram: telegram,
      logger: logger,
      bot_config: { "chat_id_allowlist" => [ 12345 ], "notification_dedupe_window_sec" => 300 },
      daemon_enabled: daemon_enabled,
      now: -> { @clock }
    )
  end

  def telegram
    @telegram ||= StubTelegram.new
  end

  def logger
    @logger ||= StubLogger.new
  end

  def test_process_rows_sends_new_input_gate_notification
    dispatcher.process_rows([ row ])

    assert_equal 1, telegram.messages.size
    assert_equal 12345, telegram.messages.first[:chat_id]
    assert_match(/Brainstorm questions/, telegram.messages.first[:text])
    assert_equal :notification_sent, logger.events.last.first
  end

  def test_process_rows_dedupes_same_marker_fingerprint
    d = dispatcher
    d.process_rows([ row ])
    d.process_rows([ row ])

    assert_equal 1, telegram.messages.size
    assert_equal :notification_skipped_dedupe, logger.events.last.first
  end

  def test_marker_attr_change_renotifies
    d = dispatcher
    d.process_rows([ row(action: "recover_review", marker: "review_error", attrs: { "pass" => "2" }) ])
    d.process_rows([ row(action: "recover_review", marker: "review_error", attrs: { "pass" => "3" }) ])

    assert_equal 2, telegram.messages.size
  end

  def test_ready_action_suppressed_when_daemon_enabled
    d = dispatcher(daemon_enabled: ->(_project) { true })
    d.process_rows([ row(action: "ready_to_plan", marker: "complete") ])

    assert_equal [], telegram.messages
  end

  def test_recent_dispatch_suppresses_notification
    d = dispatcher
    d.record_dispatch(project: "hive", slug: "slug-260514-abcd")
    d.process_rows([ row(action: "needs_input", marker: "waiting") ])

    assert_equal [], telegram.messages
  end

  class StubTelegram
    attr_reader :messages

    def initialize
      @messages = []
    end

    def send_message(chat_id:, text:, reply_markup: nil, parse_mode: :markdown)
      @messages << { chat_id: chat_id, text: text, reply_markup: reply_markup, parse_mode: parse_mode }
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
  end
end
