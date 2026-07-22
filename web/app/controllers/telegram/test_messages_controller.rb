module Telegram
  class TestMessagesController < BaseController
    def create
      load_telegram_page
      result = @telegram_bot.send_test_message
      if result[:ok]
        flash.now[:notice] = "Sent a test message to #{result[:sent]} chat(s)."
        render "telegram/show"
      else
        render_telegram_error("Telegram test failed: #{result[:error]}.")
      end
    rescue TelegramBot::InvalidSettings => e
      render_telegram_error(e.message)
    end
  end
end
