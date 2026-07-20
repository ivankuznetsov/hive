module Telegram
  class BaseController < ApplicationController
    private

    def load_telegram_page
      @telegram_bot = TelegramBot.current
      @pairings = []
      return unless @telegram_bot.pairing_enabled?

      begin
        @pairings = @telegram_bot.pending_pairings
      rescue Hive::Error => e
        @pairing_error = e.message
      end
    end

    def render_telegram_error(message)
      load_telegram_page
      flash.now[:alert] = message
      render "telegram/show", status: :unprocessable_entity
    end
  end
end
