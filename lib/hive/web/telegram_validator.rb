require "telegram/bot"

module Hive
  module Web
    # Validates a Telegram bot token against the real Telegram API before the
    # web UI persists it. U6 requires "invalid token → nothing persisted", so
    # the token is only saved when `getMe` confirms it is a working bot token.
    #
    # A bad/revoked token comes back as a 401 ResponseError → false (reject,
    # nothing saved). Network/transport failures are NOT swallowed: they
    # propagate so the route surfaces a "couldn't reach Telegram" error page
    # rather than silently rejecting a good token during a Telegram outage.
    module TelegramValidator
      module_function

      def call(token)
        response = ::Telegram::Bot::Client.new(token.to_s).api.get_me
        response.is_a?(Hash) && response["ok"] ? true : false
      rescue ::Telegram::Bot::Exceptions::ResponseError
        false
      end
    end
  end
end
