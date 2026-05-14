require "json"
require "telegram/bot"
require "hive/bot/logger"

module Hive
  module Bot
    class Telegram
      MAX_MESSAGE_CHARS = 4096
      MARKDOWN_V2_SPECIALS = /([_*\[\]()~`>#+\-=|{}.!\\])/

      Update = Struct.new(:update_id, :chat_id, :from_id, :message_id, :text,
                          :callback_data, :entities, keyword_init: true) do
        def message?
          callback_data.nil?
        end

        def text?
          !text.to_s.empty?
        end

        def callback_query?
          !callback_data.nil?
        end
      end

      attr_reader :client

      def initialize(token:, logger:, client: nil)
        @logger = logger
        @client = client || ::Telegram::Bot::Client.new(token)
      end

      def poll_updates(timeout:, since_update_id:)
        params = { timeout: timeout }
        params[:offset] = since_update_id if since_update_id
        raw_updates = client.api.get_updates(params)
        Array(raw_updates).filter_map { |raw| build_update(raw) }
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed,
             ::Telegram::Bot::Exceptions::ResponseError => e
        @logger.event(:poll_failure, error_class: e.class.name, message: e.message)
        []
      end

      def send_message(chat_id:, text:, reply_markup: nil, parse_mode: :markdown)
        chunks = split_message(text)
        chunks.map.with_index do |chunk, idx|
          params = {
            chat_id: chat_id,
            text: chunk,
            parse_mode: parse_mode_value(parse_mode)
          }
          params[:reply_markup] = inline_keyboard(reply_markup) if reply_markup && idx == chunks.length - 1
          client.api.send_message(params)
        end
      end

      def edit_message_reply_markup(chat_id:, message_id:, reply_markup: nil)
        params = { chat_id: chat_id, message_id: message_id }
        params[:reply_markup] = inline_keyboard(reply_markup) if reply_markup
        client.api.edit_message_reply_markup(params)
      end

      def self.escape_markdown_v2(text)
        text.to_s.gsub(MARKDOWN_V2_SPECIALS, '\\\\\1')
      end

      private

      def build_update(raw)
        update_id = value(raw, :update_id)
        message = value(raw, :message)
        callback = value(raw, :callback_query)
        source_message = callback ? value(callback, :message) : message
        chat = value(source_message, :chat)
        from = callback ? value(callback, :from) : value(message, :from)
        chat_id = value(chat, :id)
        from_id = value(from, :id)

        unless update_id && chat_id
          @logger.event(:poll_failure, error_class: "MalformedUpdate",
                                       message: "missing update_id or chat_id")
          return nil
        end

        Update.new(
          update_id: update_id,
          chat_id: chat_id,
          from_id: from_id,
          message_id: value(source_message, :message_id),
          text: value(message, :text),
          callback_data: value(callback, :data),
          entities: Array(value(message, :entities))
        )
      rescue StandardError => e
        @logger.event(:poll_failure, error_class: e.class.name, message: e.message)
        nil
      end

      def value(object, key)
        return nil if object.nil?
        return object[key] || object[key.to_s] if object.is_a?(Hash)
        return object.public_send(key) if object.respond_to?(key)

        nil
      end

      def split_message(text)
        body = text.to_s.dup
        return [ "" ] if body.empty?

        chunks = []
        until body.empty?
          chunks << body.slice!(0, MAX_MESSAGE_CHARS)
        end
        chunks
      end

      def inline_keyboard(rows)
        keyboard = Array(rows).map do |row|
          Array(row).map do |button|
            ::Telegram::Bot::Types::InlineKeyboardButton.new(
              text: button.fetch(:text),
              callback_data: button.fetch(:callback_data)
            )
          end
        end
        ::Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: keyboard)
      end

      def parse_mode_value(parse_mode)
        case parse_mode
        when :markdown then "Markdown"
        when :markdown_v2 then "MarkdownV2"
        when :html then "HTML"
        else parse_mode.to_s
        end
      end
    end
  end
end
