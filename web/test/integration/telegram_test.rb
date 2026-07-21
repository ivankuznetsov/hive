require "test_helper"
require "hive/env_file"

class TelegramTest < ActionDispatch::IntegrationTest
  setup do
    @original_telegram_token = ENV.delete("HIVE_TELEGRAM_BOT_TOKEN")
    FileUtils.rm_f(Hive::EnvFile::DEFAULT_PATH)
    Hive::Config.update_global_config! do |data|
      data["bot"] = {
        "enabled" => false,
        "pairing_enabled" => false,
        "chat_id_allowlist" => []
      }
    end
  end

  teardown do
    TelegramBot.reset_pairing_gateway!
    if @original_telegram_token
      ENV["HIVE_TELEGRAM_BOT_TOKEN"] = @original_telegram_token
    else
      ENV.delete("HIVE_TELEGRAM_BOT_TOKEN")
    end
  end

  test "the page walks a first-timer through bot setup" do
    sign_in!
    get "/telegram"
    assert_response :success
    assert_select ".setup-guide[open]", 1,
                  "the guide must start expanded while the bot is unconfigured"
    assert_select ".setup-guide a[href='https://t.me/BotFather']", 1
    assert_select ".setup-guide a[href='https://t.me/userinfobot']", 1
    assert_select ".setup-steps li", 3, "three steps: create, chat id, say hello"
  end

  test "blank chat IDs are a 422 before anything is saved or sent to Telegram" do
    sign_in!
    post "/telegram", params: { token: "123:abc", chat_ids: "  " }

    assert_response :unprocessable_entity
    assert_match "At least one numeric chat ID", response.body
    refute Hive::Config.load_global_bot["enabled"],
           "a rejected submit must not flip bot.enabled"
  end

  test "blank token without a saved secret is a 422" do
    sign_in!

    post update_telegram_path,
         params: { token: "", chat_ids: "123456", pairing_enabled: "0" }

    assert_response :unprocessable_entity
    assert_match "token required", response.body
    refute Hive::Config.load_global_bot["enabled"]
  end

  test "a @handle chat ID is a readable 422, not a silent 0 in the allowlist" do
    sign_in!
    post "/telegram", params: { token: "123:abc", chat_ids: "@mychannel" }

    assert_response :unprocessable_entity
    assert_match "@mychannel", response.body
    assert_empty Hive::Config.load_global_bot["chat_id_allowlist"].to_a,
                 "no allowlist may be persisted from invalid input"
  end

  test "pairing mode can start securely without a pre-known chat ID" do
    sign_in!
    with_valid_telegram_token do
      post update_telegram_path,
           params: { token: "123:abc", chat_ids: "", pairing_enabled: "1" }
    end

    assert_redirected_to telegram_path
    bot = Hive::Config.load_global_bot
    assert_equal true, bot.fetch("enabled")
    assert_equal true, bot.fetch("pairing_enabled")
    assert_empty bot.fetch("chat_id_allowlist")
  end

  test "saved token can be kept while changing authorization settings" do
    FileUtils.mkdir_p(File.dirname(Hive::EnvFile::DEFAULT_PATH))
    File.write(Hive::EnvFile::DEFAULT_PATH, "HIVE_TELEGRAM_BOT_TOKEN=123:existing\n", mode: "w", perm: 0o600)
    sign_in!

    post update_telegram_path,
         params: { token: "", chat_ids: "123456", pairing_enabled: "0" }

    assert_redirected_to telegram_path
    bot = Hive::Config.load_global_bot
    assert_equal [ 123_456 ], bot.fetch("chat_id_allowlist")
    assert_equal false, bot.fetch("pairing_enabled")
    assert_equal "HIVE_TELEGRAM_BOT_TOKEN=123:existing\n", File.read(Hive::EnvFile::DEFAULT_PATH),
                 "a settings-only save must not rewrite the persisted secret"
  end

  test "test delivery requires a saved token" do
    sign_in!

    post test_telegram_path

    assert_response :unprocessable_entity
    assert_select ".flash-alert", text: /Save a bot token/
  end

  test "test delivery renders the shared Telegram result" do
    ENV["HIVE_TELEGRAM_BOT_TOKEN"] = "123:existing"
    Hive::Config.update_global_config! do |data|
      data["bot"]["chat_id_allowlist"] = [ 123, 456 ]
    end
    sign_in!

    with_telegram_tester(ok: true, sent: 2) do
      post test_telegram_path
    end

    assert_response :success
    assert_select "nav a.nav-link-active", text: "Telegram"
    assert_select ".flash-notice", text: /Sent a test message to 2 chat\(s\)/
  end

  test "page lists pending pairing codes and approves through the shared lifecycle" do
    sign_in!
    enable_pairing!
    approvals = []
    install_pairing_gateway(
      pending: [
        {
          "code" => "ABCDEFGH",
          "chat_id" => 987_654,
          "created_at" => "2026-07-18T22:00:00Z",
          "age_sec" => 60,
          "expires_in_sec" => 86_340
        }
      ],
      approve: lambda do |code|
        approvals << code
        { "chat_id" => 987_654, "reloaded" => true, "notice_queued" => true }
      end
    )

    get telegram_path
    assert_response :success
    assert_select "[data-pairing-code='ABCDEFGH']", text: /987654/
    assert_select "form[action='#{telegram_pairing_approve_path("ABCDEFGH")}'] button", text: "Approve"

    post telegram_pairing_approve_path("ABCDEFGH")
    assert_response :unprocessable_entity
    assert_empty approvals, "a crafted POST without the form's consent marker must not authorize a chat"

    post telegram_pairing_approve_path("ABCDEFGH"),
         params: { consent: "approve_telegram_pairing" }

    assert_redirected_to telegram_path
    assert_equal [ "ABCDEFGH" ], approvals
    assert_match "Approved Telegram chat 987654", flash[:notice]
    assert_match "running bot was reloaded", flash[:notice]
  end

  test "pairing store is not touched while pairing is disabled" do
    sign_in!
    calls = []
    install_pairing_gateway(pending: -> { calls << :pending; [] })

    get telegram_path

    assert_response :success
    assert_empty calls
    assert_match "Enable pairing above", response.body
  end

  test "corrupt pairing store is shown as an owner-visible error, not an empty list" do
    sign_in!
    enable_pairing!
    store = Hive::Bot::PairingStore.new
    FileUtils.mkdir_p(File.dirname(store.path))
    File.write(store.path, "{not json")

    get telegram_path

    assert_response :success
    assert_select ".flash-alert", text: /failed to read pending pairing requests.*unreadable/m
    refute_match "No pending pairing requests", response.body
  ensure
    FileUtils.rm_f(store&.path)
  end

  test "expired pairing approval is a readable 422" do
    sign_in!
    enable_pairing!
    install_pairing_gateway(
      pending: [],
      approve: ->(_code) do
        raise Hive::Commands::Pairing::ApprovalError.new(
          "pairing code ABCDEFGH expired; refresh the page and ask the user to run /start again",
          error_kind: "expired_code"
        )
      end
    )

    post telegram_pairing_approve_path("ABCDEFGH"),
         params: { consent: "approve_telegram_pairing" }

    assert_response :unprocessable_entity
    assert_match(/expired.*refresh the page/m, response.body)
  end

  private

  def enable_pairing!
    Hive::Config.update_global_config! do |data|
      data["bot"] ||= {}
      data["bot"]["enabled"] = true
      data["bot"]["pairing_enabled"] = true
      data["bot"]["chat_id_allowlist"] ||= []
    end
  end

  def install_pairing_gateway(pending:, approve: ->(_code) { raise "unexpected approval" })
    gateway = Object.new
    if pending.respond_to?(:call)
      gateway.define_singleton_method(:pending, &pending)
    else
      gateway.define_singleton_method(:pending) { pending }
    end
    gateway.define_singleton_method(:approve, &approve)
    TelegramBot.pairing_gateway = gateway
  end

  def with_valid_telegram_token
    original = Hive::Web::TelegramValidator.method(:call)
    Hive::Web::TelegramValidator.define_singleton_method(:call) { |_token| true }
    yield
  ensure
    Hive::Web::TelegramValidator.define_singleton_method(:call, original)
  end

  def with_telegram_tester(result)
    original = Hive::Web::TelegramTester.method(:call)
    Hive::Web::TelegramTester.define_singleton_method(:call) do |token:, chat_ids:|
      raise "wrong token" unless token == "123:existing"
      raise "wrong chats" unless chat_ids == [ 123, 456 ]

      result
    end
    yield
  ensure
    Hive::Web::TelegramTester.define_singleton_method(:call, original)
  end
end
