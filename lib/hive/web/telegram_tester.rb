require "telegram/bot"
require "hive/web/telegram_timeouts"

module Hive
  module Web
    # Confirms the saved Telegram bot token works end to end (U6 round-trip):
    # `getMe` authenticates the token, then `sendMessage` proves the bot can
    # actually deliver to each configured chat. Injected into the app like
    # TelegramValidator so the route can be unit-tested with a fake while the
    # production default talks to the real Telegram API.
    module TelegramTester
      module_function

      TEST_MESSAGE = "✅ hivebox test message".freeze

      # `url:` overrides the Telegram API base (the gem's own Client option) so
      # tests can drive the real network-error path against an unroutable
      # address; production leaves it nil → api.telegram.org.
      def call(token:, chat_ids:, url: nil)
        chats = Array(chat_ids)
        return { ok: false, error: "no allowed chat IDs configured" } if chats.empty?

        client = url ? ::Telegram::Bot::Client.new(token.to_s, url: url) : ::Telegram::Bot::Client.new(token.to_s)
        # getMe authenticates the token: a bad/revoked token raises ResponseError
        # (rescued below into a failure result), so reaching past it means the
        # token is valid and we can prove delivery to each chat.
        client.api.get_me
        chats.each { |chat_id| client.api.send_message(chat_id: chat_id, text: TEST_MESSAGE) }
        { ok: true, sent: chats.length }
      rescue ::Telegram::Bot::Exceptions::ResponseError => e
        { ok: false, error: e.message }
      rescue *TelegramTimeouts::NETWORK_ERRORS => e
        # A transport failure (timeout / connection refused / DNS) would
        # otherwise escape to the request thread as an opaque 500 after a long
        # block. Convert it to Hive::Error so the app renders a friendly
        # "couldn't reach Telegram" page.
        raise Hive::Error, "couldn't reach Telegram to send the test message (#{e.class}). Try again."
      end
    end
  end
end
