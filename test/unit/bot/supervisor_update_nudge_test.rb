require "test_helper"
require "tmpdir"
require "hive/bot/supervisor"
require "hive/update_check/state"

# Pins the bot's once-per-version update push (plan 2026-05-27-002, U5).
class HiveBotSupervisorUpdateNudgeTest < Minitest::Test
  FakeTelegram = Struct.new(:messages, :fail_first, :fail_all, keyword_init: true) do
    def send_message(chat_id:, text:, reply_markup: nil)
      raise "telegram down" if fail_all
      if fail_first && messages.empty? && !@failed
        @failed = true
        raise "telegram boom"
      end
      messages << { chat_id: chat_id, text: text }
    end
  end

  FakeLogger = Struct.new(:events, keyword_init: true) do
    def event(name, **payload) = events << { name: name, payload: payload }
    def close; end
  end

  def setup
    @dir = Dir.mktmpdir
    @state = Hive::UpdateCheck::State.new(path: File.join(@dir, "update_check.json"))
    @telegram = FakeTelegram.new(messages: [])
    @logger = FakeLogger.new(events: [])
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def supervisor(telegram: @telegram)
    Hive::Bot::Supervisor.new(
      config: { "chat_id_allowlist" => [ 42, 43 ], "conversation_ttl_sec" => 60, "poll_interval_sec" => 1 },
      token: "t", logger: @logger, telegram: telegram,
      status_watcher: Object.new, notification_dispatcher: Object.new,
      router: Object.new, child_supervisor: Object.new,
      conversation_store: Object.new, update_state: @state
    )
  end

  def event_names
    @logger.events.map { |e| e[:name] }
  end

  def test_pushes_once_to_allowlist_when_nudge_present
    @state.set_nudge(latest: "0.1.7", channel: "brew", command: "brew upgrade ivankuznetsov/hive/hive")
    sup = supervisor
    sup.send(:push_update_nudge)

    assert_equal [ 42, 43 ], @telegram.messages.map { |m| m[:chat_id] }
    assert_match(/0\.1\.7 is available/, @telegram.messages.first[:text])
    assert_match(/brew upgrade ivankuznetsov\/hive\/hive/, @telegram.messages.first[:text])
    assert_includes event_names, :update_nudge_pushed
  end

  def test_does_not_repush_same_version
    @state.set_nudge(latest: "0.1.7", channel: "brew", command: "brew upgrade x")
    sup = supervisor
    sup.send(:push_update_nudge)
    sup.send(:push_update_nudge)
    assert_equal 2, @telegram.messages.size, "two chats, one version, one round of pushes"
  end

  def test_no_push_when_no_nudge
    supervisor.send(:push_update_nudge)
    assert_empty @telegram.messages
  end

  def test_all_sends_fail_does_not_record_and_retries_next_tick
    failing = FakeTelegram.new(messages: [], fail_all: true)
    @state.set_nudge(latest: "0.1.7", channel: "brew", command: "brew upgrade x")
    sup = supervisor(telegram: failing)
    sup.send(:push_update_nudge)

    assert_empty failing.messages
    assert @state.should_notify?("0.1.7"),
           "a total send failure must NOT mark notified, so the next tick retries"
    refute_includes event_names, :update_nudge_pushed
  end

  def test_partial_success_records_notified
    # First chat's send raises (swallowed by safe_send_message → nil); the
    # second chat delivers. Since something was delivered, the version is
    # recorded as notified and won't be re-pushed.
    failing = FakeTelegram.new(messages: [], fail_first: true)
    @state.set_nudge(latest: "0.1.7", channel: "brew", command: "brew upgrade x")
    sup = supervisor(telegram: failing)
    sup.send(:push_update_nudge)
    refute @state.should_notify?("0.1.7"), "a partial success still records the version as notified"
  end
end
