require "test_helper"
require "hive/bot/supervisor"
require "hive/bot/status_watcher"
require "hive/bot/telegram"

class HiveBotScenarioQueueTest < Minitest::Test
  Row = Hive::Bot::StatusWatcher::Row

  def test_s3_queue_renders_actionable_rows
    telegram = FakeTelegram.new
    supervisor = Hive::Bot::Supervisor.new(
      config: bot_config,
      token: "token",
      logger: FakeLogger.new,
      telegram: telegram,
      status_watcher: FakeStatusWatcher.new(rows),
      notification_dispatcher: FakeNotificationDispatcher.new,
      child_supervisor: FakeChildSupervisor.new
    )

    supervisor.process_update(update("/queue"))

    text = telegram.messages.last[:text]
    assert_match(/4 active tasks/, text)
    assert_match(/Brainstorm a… — Brainstorm/, text)
    assert_match(/Review a… — Brainstorm/, text)
    assert_match(/Pr a… — Brainstorm/, text)
    refute_match(/hive\/brainstorm-a/, text)
    refute_match(/archived-a/, text)

    assert_nil telegram.messages.last[:reply_markup]
  end

  def test_s3_queue_caps_at_10_rows_and_shows_more_affordance
    telegram = FakeTelegram.new
    overflow_rows = 12.times.map do |i|
      row(slug: "slug-#{i}", action: "needs_input", marker: "waiting")
    end
    supervisor = Hive::Bot::Supervisor.new(
      config: bot_config,
      token: "token",
      logger: FakeLogger.new,
      telegram: telegram,
      status_watcher: FakeStatusWatcher.new(overflow_rows),
      notification_dispatcher: FakeNotificationDispatcher.new,
      child_supervisor: FakeChildSupervisor.new
    )

    supervisor.process_update(update("/queue"))

    text = telegram.messages.last[:text]
    assert_match(/12 active tasks/, text)
    assert_match(/\+ 2 more tasks/, text)
    refute text.length > Hive::Bot::Telegram::MAX_MESSAGE_CHARS,
           "queue summary should never blow Telegram's char cap"
  end

  def test_s3_unauthorized_chat_id_produces_no_send_or_dispatch
    telegram = FakeTelegram.new
    child = FakeChildSupervisor.new
    supervisor = Hive::Bot::Supervisor.new(
      config: bot_config,
      token: "token",
      logger: FakeLogger.new,
      telegram: telegram,
      status_watcher: FakeStatusWatcher.new(rows),
      notification_dispatcher: FakeNotificationDispatcher.new,
      child_supervisor: child
    )

    hostile = Hive::Bot::Telegram::Update.new(update_id: 99, chat_id: 99999,
                                              from_id: 99999, text: "/status")
    supervisor.process_update(hostile)

    assert_empty telegram.messages, "unauthorized chat must not receive any reply"
    refute child.dispatched?, "unauthorized chat must not trigger child dispatch"
  end

  private

  def rows
    [
      row(slug: "brainstorm-a", action: "needs_input", marker: "waiting"),
      row(slug: "brainstorm-b", action: "needs_input", marker: "waiting"),
      row(slug: "review-a", action: "needs_input", marker: "review_waiting"),
      row(slug: "pr-a", action: "ready_to_finalize", marker: "complete"),
      row(slug: "archived-a", action: "archived", marker: nil)
    ]
  end

  def row(slug:, action:, marker:)
    Row.new(project: "hive", slug: slug, stage: "2-brainstorm", action: action,
            action_label: action.tr("_", " "), marker: marker, attrs: {})
  end

  def update(text)
    Hive::Bot::Telegram::Update.new(update_id: 1, chat_id: 12345, from_id: 12345, text: text)
  end

  def bot_config
    {
      "chat_id_allowlist" => [ 12345 ],
      "conversation_ttl_sec" => 3600,
      "long_poll_timeout_sec" => 25,
      "poll_interval_sec" => 30,
      "notification_dedupe_window_sec" => 300,
      "shutdown_grace_sec" => 1,
      "last_seen_state_file" => nil
    }
  end

  class FakeLogger
    def event(_name, **_attrs); end
    def close; end
  end

  class FakeTelegram
    attr_reader :messages
    def initialize = @messages = []
    def send_message(chat_id:, text:, reply_markup: nil, parse_mode: :markdown)
      @messages << { chat_id: chat_id, text: text, reply_markup: reply_markup, parse_mode: parse_mode }
    end
  end

  class FakeStatusWatcher
    Result = Struct.new(:ok, :rows, :error, keyword_init: true)
    def initialize(rows) = @rows = rows
    def fetch = Result.new(ok: true, rows: @rows, error: nil)
  end

  class FakeNotificationDispatcher
    def process_rows(_rows); end
    def record_dispatch(project:, slug:); end
  end

  class FakeChildSupervisor
    attr_reader :dispatches
    def initialize = @dispatches = []
    def dispatch(**opts)
      @dispatches << opts
      123
    end
    def reap_all = []
    def terminate_all(grace_sec:); end
    def in_flight_count = 0
    def dispatched? = !@dispatches.empty?
  end
end
