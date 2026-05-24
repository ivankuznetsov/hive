require "digest"
require "json"
require "hive/bot/telegram"

module Hive
  module Eval
    class FakeTelegram
      DEFAULT_CHAT_ID = 12345
      DEFAULT_USER_ID = 12345

      Sent = Struct.new(
        :chat_id,
        :text,
        :reply_markup,
        :parse_mode,
        :t,
        :fingerprint,
        :source,
        :row,
        :intent,
        :child,
        keyword_init: true
      )
      Edit = Struct.new(:chat_id, :message_id, :reply_markup, :t, keyword_init: true)
      CallbackAnswer = Struct.new(:callback_query_id, :text, :show_alert, :t, keyword_init: true)

      attr_reader :sent, :edits, :answered_callbacks

      def initialize(now: -> { Time.now })
        @now = now
        @sent = []
        @edits = []
        @answered_callbacks = []
        @updates = []
      end

      def send_message(chat_id:, text:, reply_markup: nil, parse_mode: nil)
        @sent << Sent.new(
          chat_id: chat_id,
          text: text.to_s,
          reply_markup: reply_markup,
          parse_mode: parse_mode,
          t: @now.call,
          fingerprint: self.class.payload_fingerprint(text: text, reply_markup: reply_markup)
        )
        { "message_id" => @sent.length }
      end

      def edit_message_reply_markup(chat_id:, message_id:, reply_markup: nil)
        @edits << Edit.new(
          chat_id: chat_id,
          message_id: message_id,
          reply_markup: reply_markup,
          t: @now.call
        )
        true
      end

      def answer_callback_query(callback_query_id:, text: nil, show_alert: false)
        @answered_callbacks << CallbackAnswer.new(
          callback_query_id: callback_query_id,
          text: text,
          show_alert: show_alert,
          t: @now.call
        )
        true
      end

      def poll_updates(timeout:, since_update_id:)
        selected, remaining = @updates.partition do |update|
          since_update_id.nil? || update.update_id >= since_update_id
        end
        @updates = remaining
        selected
      end

      def inject_update(text:, update_id:, chat_id: DEFAULT_CHAT_ID, from_id: DEFAULT_USER_ID,
                        message_id: update_id, reply_to_text: nil)
        update = Hive::Bot::Telegram::Update.new(
          update_id: update_id,
          chat_id: chat_id,
          from_id: from_id,
          message_id: message_id,
          text: text,
          reply_to_text: reply_to_text
        )
        @updates << update
        update
      end

      def tap_button(callback_data:, update_id:, chat_id: DEFAULT_CHAT_ID,
                     from_id: DEFAULT_USER_ID, message_id: nil)
        update = Hive::Bot::Telegram::Update.new(
          update_id: update_id,
          chat_id: chat_id,
          from_id: from_id,
          message_id: message_id || @sent.length,
          callback_data: callback_data
        )
        @updates << update
        update
      end

      def messages_with_keyboard
        @sent.select { |message| !Array(message.reply_markup).empty? }
      end

      def self.payload_fingerprint(text:, reply_markup:)
        Digest::SHA256.hexdigest(JSON.generate([ text.to_s, canonical_reply_markup(reply_markup) ]))
      end

      def self.canonical_reply_markup(reply_markup)
        case reply_markup
        when nil
          nil
        when Array
          reply_markup.map { |row| canonical_reply_markup(row) }
        when Hash
          reply_markup.transform_keys(&:to_s).sort.to_h
        else
          if reply_markup.respond_to?(:to_h)
            canonical_reply_markup(reply_markup.to_h)
          else
            reply_markup.to_s
          end
        end
      end
    end
  end
end
