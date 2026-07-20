require "test_helper"
require "hive/env_file"

class TelegramBotTest < ActiveSupport::TestCase
  setup do
    @original_token = ENV.delete("HIVE_TELEGRAM_BOT_TOKEN")
    FileUtils.rm_f(Hive::EnvFile::DEFAULT_PATH)
  end

  teardown do
    TelegramBot.reset_pairing_gateway!
    if @original_token
      ENV["HIVE_TELEGRAM_BOT_TOKEN"] = @original_token
    else
      ENV.delete("HIVE_TELEGRAM_BOT_TOKEN")
    end
  end

  test "wraps bot authorization state with named behavior" do
    bot = TelegramBot.new(
      "enabled" => true,
      "pairing_enabled" => true,
      "chat_id_allowlist" => [ 123, 456 ]
    )

    assert bot.enabled?
    assert bot.pairing_enabled?
    assert_equal [ 123, 456 ], bot.chat_ids
    refute bot.token_saved?
  end

  test "wraps pending pairing rows" do
    gateway = Object.new
    gateway.define_singleton_method(:pending) do
      [
        {
          "code" => "ABCDEFGH", "chat_id" => 123,
          "age_sec" => 60, "expires_in_sec" => 3600
        }
      ]
    end
    TelegramBot.pairing_gateway = gateway

    pairing = TelegramBot.new("pairing_enabled" => true).pending_pairings.sole

    assert_equal "ABCDEFGH", pairing.code
    assert_equal 123, pairing.chat_id
    assert_equal 60, pairing.age_sec
    assert_equal 3600, pairing.expires_in_sec
  end

  test "does not inspect the pairing store while pairing is disabled" do
    gateway = Object.new
    gateway.define_singleton_method(:pending) { raise "pairing store touched" }
    TelegramBot.pairing_gateway = gateway

    assert_empty TelegramBot.new("pairing_enabled" => false).pending_pairings
  end
end
