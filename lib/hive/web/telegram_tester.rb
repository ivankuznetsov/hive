require "telegram/bot"

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

      def call(token:, chat_ids:)
        chats = Array(chat_ids)
        return { ok: false, error: "no allowed chat IDs configured" } if chats.empty?

        client = ::Telegram::Bot::Client.new(token.to_s)
        me = client.api.get_me
        return { ok: false, error: "getMe failed — token rejected" } unless me.is_a?(Hash) && me["ok"]

        chats.each { |chat_id| client.api.send_message(chat_id: chat_id, text: TEST_MESSAGE) }
        { ok: true, sent: chats.length }
      rescue ::Telegram::Bot::Exceptions::ResponseError => e
        { ok: false, error: e.message }
      end
    end
  end
end
