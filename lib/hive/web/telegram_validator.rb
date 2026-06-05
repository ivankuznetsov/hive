require "telegram/bot"
require "hive/web/telegram_timeouts"

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

      # `url:` overrides the Telegram API base (the gem's own Client option).
      # Production leaves it nil → api.telegram.org; tests point it at an
      # unroutable address to exercise the real network-error path without
      # stubbing the gem.
      def call(token, url: nil)
        client = url ? ::Telegram::Bot::Client.new(token.to_s, url: url) : ::Telegram::Bot::Client.new(token.to_s)
        # The gem raises ResponseError for a bad/revoked token and otherwise
        # returns a truthy Types::User for getMe. Reaching a non-nil answer here
        # means the token authenticated — there is no "returned but not ok"
        # shape to second-guess.
        !client.api.get_me.nil?
      rescue ::Telegram::Bot::Exceptions::ResponseError
        false
      rescue *TelegramTimeouts::NETWORK_ERRORS => e
        # A transport failure is NOT "bad token" — don't silently reject a good
        # token during a Telegram outage. Surface it as Hive::Error so the
        # app's `error Hive::Error` handler renders a friendly page instead of
        # an opaque blank 500 after the default 20s Faraday block.
        raise Hive::Error, "couldn't reach Telegram to validate the token (#{e.class}). Try again."
      end
    end
  end
end
