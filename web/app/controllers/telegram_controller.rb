class TelegramController < Telegram::BaseController
  def show
    load_telegram_page
  end

  def update
    TelegramBot.current.update!(
      entered_token: params[:token],
      chat_ids: params[:chat_ids],
      pairing_enabled: params[:pairing_enabled] == "1"
    )
    redirect_to telegram_path,
                notice: "Telegram settings saved. Restart the bot to apply them " \
                        "(hive bot stop && hive bot start)."
  rescue TelegramBot::InvalidSettings => e
    render_telegram_error(e.message)
  end
end
