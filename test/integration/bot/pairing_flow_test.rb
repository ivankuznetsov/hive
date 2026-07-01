require "test_helper"
require "json"
require "yaml"
require "hive/config"
require "hive/bot/supervisor"
require "hive/bot/telegram"
require "hive/bot/pairing_store"
require "hive/bot/pairing_approval_queue"
require "hive/commands/pairing"

class HiveBotPairingFlowTest < Minitest::Test
  include HiveTestHelper

  FakeTelegram = Struct.new(:messages, keyword_init: true) do
    def send_message(chat_id:, text:, reply_markup: nil, parse_mode: nil)
      messages << { chat_id: chat_id, text: text, reply_markup: reply_markup, parse_mode: parse_mode }
    end
  end

  FakeLogger = Struct.new(:events, keyword_init: true) do
    def event(name, **payload)
      events << { name: name, payload: payload }
    end

    def close; end
  end

  FakeNotificationDispatcher = Struct.new(:processed, keyword_init: true) do
    def process_rows(rows)
      processed << rows
    end
  end

  FakeProcess = Struct.new(:kills, keyword_init: true) do
    def kill(signal, pid)
      kills << [ signal, pid ]
      true
    end
  end

  def test_telegram_pairing_happy_path_and_rejection_edges
    with_tmp_global_config do |home|
      write_pairing_config(home)
      current = Time.utc(2026, 6, 30, 12, 0, 0)
      pairing_store = Hive::Bot::PairingStore.new(state_home: home, now: -> { current })

      with_env("HIVE_TELEGRAM_BOT_TOKEN" => "test-token") do
        config = Hive::Config.load_global_bot(require_runtime: true)
        assert_equal [], config.fetch("chat_id_allowlist")
        assert_equal true, config.fetch("pairing_enabled")

        telegram = FakeTelegram.new(messages: [])
        supervisor = supervisor(config: config, telegram: telegram, pairing_store: pairing_store)

        supervisor.process_update(update(text: "/start", chat_id: 999, update_id: 1))

        assert_equal 1, telegram.messages.size
        pairing_reply = telegram.messages.first.fetch(:text)
        assert_match(/\Ahive: access not configured\./, pairing_reply)
        assert_includes pairing_reply, "Your Telegram user id: 999"
        code = pairing_reply.match(/Pairing code: ([A-Z]{8})/)[1]
        assert_includes pairing_reply, "hive pairing approve telegram #{code}"
        assert_equal [ code ], pairing_store.pending.map(&:code)

        supervisor.process_update(update(text: "/start", chat_id: 999, update_id: 2))
        assert_equal 1, telegram.messages.size, "second /start must be throttled in one bot lifetime"

        File.write(File.join(home, ".bot.pid"), { "pid" => 4242, "started_at" => current.iso8601 }.to_yaml)
        process = FakeProcess.new(kills: [])
        approve_output = StringIO.new
        Hive::Commands::Pairing.new(
          "approve",
          args: [ "telegram", code ],
          json: true,
          output: approve_output,
          store: pairing_store,
          process: process
        ).call

        approve_payload = JSON.parse(approve_output.string)
        assert_equal true, approve_payload.fetch("ok")
        assert_equal true, approve_payload.fetch("reloaded")
        assert_equal [ [ 0, 4242 ], [ "HUP", 4242 ] ], process.kills
        assert_empty pairing_store.pending
        assert_equal [ 999 ], global_allowlist(home)
        assert_equal [ 999 ], Hive::Bot::PairingApprovalQueue.pending(state_home: home).map(&:chat_id)

        supervisor.send(:drain_pairing_approvals)
        assert_equal Hive::Bot::Supervisor::PAIRING_APPROVED_TEXT, telegram.messages.last.fetch(:text)
        assert_equal 999, telegram.messages.last.fetch(:chat_id)
        assert_empty Hive::Bot::PairingApprovalQueue.pending(state_home: home)

        reloaded_config = Hive::Config.load_global_bot
        reloaded_router = Hive::Bot::Router.new(
          bot_config: reloaded_config,
          logger: FakeLogger.new(events: []),
          conversation_store: Hive::Bot::ConversationStore.new,
          pairing_store: pairing_store
        )
        assert_equal :slash_status, reloaded_router.classify(update(text: "/status", chat_id: 999, update_id: 3))

        list_output = StringIO.new
        Hive::Commands::Pairing.new("list", json: true, output: list_output, store: pairing_store).call
        assert_empty JSON.parse(list_output.string).fetch("pending")

        expired_code = pairing_store.mint_or_get(chat_id: 888)
        current += Hive::Bot::PairingStore::EXPIRY_SEC + 1
        before_expired = File.read(File.join(home, "config.yml"))
        assert_raises(Hive::Commands::Pairing::ApprovalError) do
          Hive::Commands::Pairing.new(
            "approve",
            args: [ "telegram", expired_code ],
            output: StringIO.new,
            store: pairing_store
          ).call
        end
        assert_equal before_expired, File.read(File.join(home, "config.yml"))

        before_unknown = File.read(File.join(home, "config.yml"))
        assert_raises(Hive::Commands::Pairing::ApprovalError) do
          Hive::Commands::Pairing.new(
            "approve",
            args: [ "telegram", "ABCDEFGH" ],
            output: StringIO.new,
            store: pairing_store
          ).call
        end
        assert_equal before_unknown, File.read(File.join(home, "config.yml"))
        assert_equal [ 999 ], global_allowlist(home)
      end
    end
  end

  private

  def write_pairing_config(home)
    File.write(File.join(home, "config.yml"), {
      "registered_projects" => [],
      "bot" => {
        "enabled" => true,
        "pairing_enabled" => true,
        "chat_id_allowlist" => []
      }
    }.to_yaml)
  end

  def supervisor(config:, telegram:, pairing_store:)
    Hive::Bot::Supervisor.new(
      config: config,
      token: "test-token",
      logger: FakeLogger.new(events: []),
      telegram: telegram,
      notification_dispatcher: FakeNotificationDispatcher.new(processed: []),
      pairing_store: pairing_store
    )
  end

  def update(text:, chat_id:, update_id:)
    Hive::Bot::Telegram::Update.new(update_id: update_id, chat_id: chat_id, from_id: chat_id, text: text)
  end

  def global_allowlist(home)
    YAML.safe_load(File.read(File.join(home, "config.yml"))).dig("bot", "chat_id_allowlist")
  end
end
