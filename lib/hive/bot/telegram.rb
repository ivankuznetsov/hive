require "json"
require "telegram/bot"
require "hive/bot/logger"

module Hive
  module Bot
    class Telegram
      MAX_MESSAGE_CHARS = 4096

      Update = Data.define(:update_id, :chat_id, :from_id, :message_id, :text,
                           :callback_data, :callback_query_id, :entities, :reply_to_text,
                           :photo, :document, :voice, :caption, :media_group_id) do
        def initialize(update_id:, chat_id:, from_id: nil, message_id: nil,
                       text: nil, callback_data: nil, callback_query_id: nil,
                       entities: nil, reply_to_text: nil, photo: nil,
                       document: nil, voice: nil, caption: nil, media_group_id: nil)
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

        # Intentionally excludes voice: a voice note carries no operator
        # caption to treat as idea text, so it must NOT flip effective_text to
        # `caption`. Voice is routed separately via voice?. Do not "fix" this
        # to include voice — it would break the voice-note idea flow.
        def media?
          !photo.nil? || !document.nil?
        end

        def voice?
          !voice.nil?
        end

        def effective_text
          media? ? caption : text
        end
      end

      class DownloadError < Hive::Error; end

      attr_reader :client

      def initialize(token:, logger:, client: nil, base_url: "https://api.telegram.org",
                     http_client: nil)
        @token = token
        @base_url = base_url.to_s.delete_suffix("/")
        @http_client = http_client
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

      # Registers the bot's slash-command list with Telegram so the blue
      # quick-actions menu (shown when the operator taps the `/` icon)
      # surfaces our commands with human-readable descriptions. Idempotent
      # on Telegram's side; one call at bot start is enough.
      def set_my_commands(commands:)
        client.api.set_my_commands(commands: commands)
      end

      def get_file(file_id:)
        file = client.api.get_file(file_id: file_id)
        {
          file_path: value(file, :file_path),
          file_size: value(file, :file_size)
        }
      rescue Faraday::Error, ::Telegram::Bot::Exceptions::ResponseError => e
        # getFile can fail before any byte is downloaded: an expired/invalid
        # file_id makes Telegram raise ResponseError, and the network leg can
        # raise any Faraday error. Map both to DownloadError so the staging
        # path replies "please send it again" (AE-6) instead of letting the
        # error escape to the poll-loop rescue with no operator feedback.
        raise DownloadError, e.message
      end

      def download_file(file_path:)
        response = http_client.get(file_download_url(file_path))
        status = value(response, :status).to_i
        raise DownloadError, "telegram file download returned HTTP #{status}" unless status == 200

        value(response, :body).to_s.b
      rescue Faraday::Error => e
        raise DownloadError, e.message
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
          reply_to_text: value(reply_to, :text),
          photo: callback ? nil : extract_photo(message),
          document: callback ? nil : extract_document(message),
          voice: callback ? nil : extract_voice(message),
          caption: callback ? nil : value(message, :caption),
          media_group_id: callback ? nil : value(message, :media_group_id)
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

      def extract_photo(message)
        variants = Array(value(message, :photo))
        chosen = variants.max_by do |variant|
          [
            value(variant, :file_size).to_i,
            value(variant, :width).to_i * value(variant, :height).to_i
          ]
        end
        return nil unless chosen

        {
          file_id: value(chosen, :file_id),
          file_unique_id: value(chosen, :file_unique_id),
          file_size: value(chosen, :file_size),
          width: value(chosen, :width),
          height: value(chosen, :height)
        }
      end

      def extract_document(message)
        document = value(message, :document)
        return nil unless document

        {
          file_id: value(document, :file_id),
          file_unique_id: value(document, :file_unique_id),
          file_name: value(document, :file_name),
          mime_type: value(document, :mime_type),
          file_size: value(document, :file_size)
        }
      end

      def extract_voice(message)
        voice = value(message, :voice)
        return nil unless voice

        {
          file_id: value(voice, :file_id),
          file_unique_id: value(voice, :file_unique_id),
          duration: value(voice, :duration),
          mime_type: value(voice, :mime_type),
          file_size: value(voice, :file_size)
        }
      end

      def http_client
        @http_client ||= Faraday.new
      end

      def file_download_url(file_path)
        escaped_path = file_path.to_s.split("/").map { |part| Faraday::Utils.escape(part) }.join("/")
        "#{@base_url}/file/bot#{@token}/#{escaped_path}"
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
