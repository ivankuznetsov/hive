class TelegramController < Telegram::BaseController
  def show
    load_telegram_page
  end

  def update
    result = TelegramBot.current.update!(
      entered_token: params[:token],
      chat_ids: params[:chat_ids],
      pairing_enabled: params[:pairing_enabled] == "1"
    )
    if result.restarted?
      redirect_to telegram_path, notice: "Telegram bot configured and (re)starting"
    else
      redirect_to telegram_path,
                  notice: "Telegram settings saved. No supervisor reachable — " \
                          "restart the bot manually (hive bot stop && hive bot start)."
    end
  rescue TelegramBot::InvalidSettings => e
    render_telegram_error(e.message)
  end
end
