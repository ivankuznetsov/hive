require "json"
require "telegram/bot"
require "hive/bot/logger"

module Hive
  module Bot
    class Telegram
      MAX_MESSAGE_CHARS = 4096

      Update = Data.define(:update_id, :chat_id, :from_id, :message_id, :text,
                           :callback_data, :callback_query_id, :entities, :reply_to_text) do
        def initialize(update_id:, chat_id:, from_id: nil, message_id: nil,
                       text: nil, callback_data: nil, callback_query_id: nil,
                       entities: nil, reply_to_text: nil)
          super
        end

        def message?
          callback_data.nil? && !text.to_s.empty?
        end

        def text?
          # Callback updates intentionally do not inherit source-message text.
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
        @build_update_error_classes_seen = {}
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
      rescue StandardError => e
        @logger.event(:poll_failure, error_class: e.class.name, message: e.message)
        []
      end

      def send_message(chat_id:, text:, reply_markup: nil, parse_mode: nil)
        chunks = split_message(text)
        chunks.map.with_index do |chunk, idx|
          params = { chat_id: chat_id, text: chunk }
          params[:parse_mode] = parse_mode_value(parse_mode) if parse_mode
          params[:reply_markup] = inline_keyboard(reply_markup) if reply_markup && idx == chunks.length - 1
          client.api.send_message(params)
        end
      end

      def edit_message_reply_markup(chat_id:, message_id:, reply_markup: nil)
        params = { chat_id: chat_id, message_id: message_id }
        params[:reply_markup] = inline_keyboard(reply_markup) if reply_markup
        client.api.edit_message_reply_markup(params)
      end

      # Dismisses the spinner on a tapped inline button. Required by the
      # Telegram Bot API on every callback_query update — without it the
      # button shows a perpetual loading state for the operator. Pass an
      # optional `text` (≤200 chars) to show as a toast; leave nil for the
      # silent ACK that just clears the spinner.
      def answer_callback_query(callback_query_id:, text: nil, show_alert: false)
        params = { callback_query_id: callback_query_id }
        params[:text] = text.to_s[0, 200] if text
        params[:show_alert] = true if show_alert
        client.api.answer_callback_query(params)
      end

      private

      def build_update(raw)
        update_id = value(raw, :update_id)
        message = value(raw, :message)
        callback = value(raw, :callback_query)
        source_message = callback ? value(callback, :message) : message
        reply_to = value(message, :reply_to_message)
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
          text: callback ? nil : value(message, :text),
          callback_data: value(callback, :data),
          callback_query_id: value(callback, :id),
          entities: Array(value(message, :entities)),
          reply_to_text: value(reply_to, :text)
        )
      rescue StandardError => e
        already_seen = @build_update_error_classes_seen.key?(e.class)
        @build_update_error_classes_seen[e.class] = true
        attrs = { error_class: e.class.name, message: e.message }
        attrs[:backtrace] = Array(e.backtrace).first(10).join("\n") unless already_seen
        @logger.event(:poll_failure, **attrs)
        nil
      end

      def value(object, key)
        return nil if object.nil?
        return object[key] || object[key.to_s] if object.is_a?(Hash)
        return object.public_send(key) if object.respond_to?(key)

        nil
      end

      def split_message(text)
        body = text.to_s
        return [ "" ] if body.empty?

        chunks = []
        remaining = body.dup
        while remaining.length > MAX_MESSAGE_CHARS
          slice = remaining[0, MAX_MESSAGE_CHARS]
          break_point = slice.rindex("\n")
          break_point ||= MAX_MESSAGE_CHARS
          chunks << remaining[0, break_point].sub(/\n\z/, "")
          remaining = remaining[break_point..]
          remaining = remaining.sub(/\A\n/, "") if break_point == slice.rindex("\n")
        end
        chunks << remaining unless remaining.empty?
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
