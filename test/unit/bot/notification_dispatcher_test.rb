require "test_helper"
require "hive/bot/status_watcher"
require "hive/bot/notification_dispatcher"

class HiveBotNotificationDispatcherTest < Minitest::Test
  include HiveTestHelper

  Row = Hive::Bot::StatusWatcher::Row

  def row(action: "needs_input", marker: "waiting", attrs: {}, slug: "slug-260514-abcd", stage: "2-brainstorm")
    Row.new(
      project: "hive",
      slug: slug,
      stage: stage,
      marker: marker,
      attrs: attrs,
      action: action,
      action_label: "Needs your input",
      folder: "/tmp/#{slug}",
      suggested_command: "hive brainstorm #{slug}"
    )
  end

  def recovery_row(attrs: { "pass" => "1" }, slug: "stuck-task-260525-abcd", stage: "6-review")
    row(action: "recover_review", marker: "review_error", attrs: attrs, slug: slug, stage: stage)
  end

  def dispatcher(path: nil, now: Time.utc(2026, 5, 25, 10, 0, 0), daemon_enabled: ->(_project) { false },
                 telegram: self.telegram)
    @clock = now
    Hive::Bot::NotificationDispatcher.new(
      telegram: telegram,
      logger: logger,
      bot_config: {
        "chat_id_allowlist" => [ 12345 ],
        "alert_state_file" => path,
        "recovery_reminder_window_sec" => 28_800
      },
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

  def test_same_row_twice_sends_one_notification
    d = dispatcher
    d.process_rows([ row ])
    d.process_rows([ row ])

    assert_equal 1, telegram.messages.size
    assert_equal :notification_skipped_dedupe, logger.events.last.first
  end

  def test_recovery_row_disappears_sends_recovered_message_and_removes_entry
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      d = dispatcher(path: path)
      d.process_rows([ recovery_row ])

      d.process_rows([])

      assert_equal 2, telegram.messages.size
      assert_equal "✅ Recovered: \"Stuck task…\" — Review", telegram.messages.last[:text]
      assert_nil Hive::Bot::AlertStore.new(path: path).entry(
        Hive::Bot::NotificationBuilders.fingerprint(recovery_row)
      )
    end
  end

  def test_non_recovery_row_disappears_silently_drops_entry
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      d = dispatcher(path: path)
      d.process_rows([ row ])

      d.process_rows([])

      assert_equal 1, telegram.messages.size
      assert_equal [], Hive::Bot::AlertStore.new(path: path).each_fingerprint.to_a
    end
  end

  def test_same_fingerprint_reappears_after_recovery_refires
    d = dispatcher
    d.process_rows([ recovery_row ])
    d.process_rows([])
    d.process_rows([ recovery_row ])

    assert_equal 3, telegram.messages.size
    assert_match(/Review stuck/, telegram.messages.first[:text])
    assert_match(/Recovered/, telegram.messages[1][:text])
    assert_match(/Review stuck/, telegram.messages.last[:text])
  end

  def test_marker_attr_change_renotifies
    d = dispatcher
    d.process_rows([ recovery_row(attrs: { "pass" => "2" }) ])
    d.process_rows([ recovery_row(attrs: { "pass" => "3" }) ])

    assert_equal 3, telegram.messages.size
    assert_match(/Recovered/, telegram.messages[1][:text])
  end

  def test_eight_hour_reminder_fires_exactly_once
    d = dispatcher
    d.process_rows([ recovery_row ])
    @clock += 28_800
    d.process_rows([ recovery_row ])
    @clock += 28_800
    d.process_rows([ recovery_row ])

    assert_equal 2, telegram.messages.size
    assert_match(/\A⚠ Still stuck \(8 h\) — "Stuck task…" — Review/, telegram.messages.last[:text])
  end

  def test_ninety_minute_reminder_fires_with_minutes_label
    d = Hive::Bot::NotificationDispatcher.new(
      telegram: telegram,
      logger: logger,
      bot_config: {
        "chat_id_allowlist" => [ 12345 ],
        "recovery_reminder_window_sec" => 5400
      },
      now: -> { @clock ||= Time.utc(2026, 5, 25, 10, 0, 0) }
    )
    @clock = Time.utc(2026, 5, 25, 10, 0, 0)
    d.process_rows([ recovery_row ])
    @clock += 5400
    d.process_rows([ recovery_row ])

    assert_equal 2, telegram.messages.size, "reminder should fire after 90 min"
    assert_match(/Still stuck \(90 min\)/, telegram.messages.last[:text],
                 "reminder label must use minutes form for non-whole-hour windows")
  end

  def test_restart_simulation_does_not_refire_same_active_row
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      dispatcher(path: path).process_rows([ recovery_row ])

      fresh = dispatcher(path: path)
      fresh.process_rows([ recovery_row ])

      assert_equal 1, telegram.messages.size
    end
  end

  def test_corrupt_store_starts_fresh_without_crashing
    with_tmp_dir do |dir|
      path = File.join(dir, "alerts.json")
      File.write(path, "{")

      dispatcher(path: path).process_rows([ recovery_row ])

      assert_equal 1, telegram.messages.size
      assert_equal :alert_store_corrupt, logger.events.first.first
      assert Dir.glob("#{path}.corrupt-*").any?
    end
  end

  def test_ready_action_suppressed_when_daemon_enabled
    d = dispatcher(daemon_enabled: ->(_project) { true })
    d.process_rows([ row(action: "ready_to_plan", marker: "complete") ])

    assert_equal [], telegram.messages
  end

  def test_multi_chat_fanout_delivers_to_all_allowed_chats
    multi = Hive::Bot::NotificationDispatcher.new(
      telegram: telegram,
      logger: logger,
      bot_config: { "chat_id_allowlist" => [ 12345, 67890 ], "recovery_reminder_window_sec" => 28_800 },
      now: -> { @clock ||= Time.utc(2026, 5, 25, 10, 0, 0) }
    )
    multi.process_rows([ row ])

    assert_equal [ 12345, 67890 ], telegram.messages.map { |msg| msg[:chat_id] }
  end

  def test_rows_without_notification_are_ignored
    dispatcher.process_rows([ row(action: "agent_running", marker: "agent_working") ])

    assert_empty telegram.messages
    assert_empty logger.events
  end

  def test_send_failures_are_logged_without_marking_seen
    flaky_telegram = FlakyTelegram.new
    d = dispatcher(telegram: flaky_telegram)

    d.process_rows([ row ])

    assert_empty flaky_telegram.messages
    assert_equal :send_failure, logger.events.last.first
    assert_equal "IOError", logger.events.last.last[:error_class]

    d.process_rows([ row ])

    assert_equal 1, flaky_telegram.messages.size
    assert_equal :notification_sent, logger.events.last.first
  end

  def test_ready_action_uses_config_fallback_when_no_daemon_probe
    projects = []
    loads = []
    with_config_stubs(
      find_project: ->(project) { projects << project; { "path" => "/tmp/hive" } },
      load: ->(path) { loads << path; { "daemon" => { "enabled" => true } } }
    ) do
      d = dispatcher(daemon_enabled: nil)
      d.process_rows([ row(action: "ready_to_plan", marker: "complete") ])
    end

    assert_empty telegram.messages
    assert_equal [ "hive" ], projects
    assert_equal [ "/tmp/hive" ], loads
  end

  def test_ready_action_not_suppressed_when_project_missing_from_config
    projects = []
    loads = []
    with_config_stubs(
      find_project: ->(project) { projects << project; nil },
      load: ->(_path) { loads << path; raise "Config.load should not be called" }
    ) do
      d = dispatcher(daemon_enabled: nil)
      d.process_rows([ row(action: "ready_to_plan", marker: "complete") ])
    end

    assert_equal 1, telegram.messages.size
    assert_equal [ "hive" ], projects
    assert_empty loads
  end

  def test_daemon_config_errors_are_logged_and_do_not_suppress_ready_actions
    with_config_stubs(
      find_project: ->(_project) { { "path" => "/tmp/hive" } },
      load: ->(_path) { raise Hive::ConfigError, "bad config" }
    ) do
      d = dispatcher(daemon_enabled: nil)
      d.process_rows([ row(action: "ready_to_plan", marker: "complete") ])
    end

    assert_equal 1, telegram.messages.size
    event = logger.events.find { |name, _attrs| name == :poll_failure }
    assert_equal "daemon_check", event.last[:source]
    assert_equal "hive", event.last[:project]
    assert_equal "Hive::ConfigError", event.last[:error_class]
  end

  def with_config_stubs(find_project:, load:)
    original_find_project = Hive::Config.method(:find_project)
    original_load = Hive::Config.method(:load)
    Hive::Config.define_singleton_method(:find_project, &find_project)
    Hive::Config.define_singleton_method(:load, &load)
    yield
  ensure
    Hive::Config.define_singleton_method(:find_project, original_find_project)
    Hive::Config.define_singleton_method(:load, original_load)
  end

  class FlakyTelegram
    attr_reader :messages

    def initialize
      @messages = []
      @fail_next = true
    end

    def send_message(chat_id:, text:, reply_markup: nil, parse_mode: :markdown)
      if @fail_next
        @fail_next = false
        raise IOError, "delivery failed"
      end

      @messages << { chat_id: chat_id, text: text, reply_markup: reply_markup, parse_mode: parse_mode }
    end
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
