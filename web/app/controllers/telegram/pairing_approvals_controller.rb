module Telegram
  class PairingApprovalsController < BaseController
    def create
      result = TelegramBot.current.approve_pairing!(
        code: params[:code], consent: params[:consent]
      )
      notice = "Approved Telegram chat #{result.fetch('chat_id')}."
      notice += if result["reloaded"]
        " The running bot was reloaded."
      else
        " Restart the bot to load the updated allowlist."
      end
      redirect_to telegram_path, notice:
    end
  end
end
