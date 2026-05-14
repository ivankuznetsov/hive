require "test_helper"
require "hive/bot/telegram"

class HiveBotTelegramSmokeTest < Minitest::Test
  def test_real_telegram_send_when_env_present
    token = ENV["HIVE_TELEGRAM_BOT_TOKEN_TEST"]
    chat_id = ENV["HIVE_TELEGRAM_CHAT_ID_TEST"]
    skip "set HIVE_TELEGRAM_BOT_TOKEN_TEST and HIVE_TELEGRAM_CHAT_ID_TEST to run" if token.to_s.empty? || chat_id.to_s.empty?

    logger = Struct.new(:events) do
      def event(name, **attrs)
        events << [ name, attrs ]
      end
    end.new([])
    bot = Hive::Bot::Telegram.new(token: token, logger: logger)
    result = bot.send_message(chat_id: Integer(chat_id), text: "hive bot smoke test")

    assert result.any?, "expected at least one Telegram API response"
  end
end
