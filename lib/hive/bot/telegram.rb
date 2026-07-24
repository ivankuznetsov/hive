require "cgi"
require "json"
require "net/http"
require "telegram/bot"
require "hive/bot/logger"
require "hive/bot/poll_health"

module Hive
  module Bot
    class Telegram
      MAX_MESSAGE_CHARS = 4096
      MARKDOWN_V2_RESERVED = "_*[]()~`>#+-=|{}.!".freeze
      BENIGN_POLL_ERRORS = [
        Faraday::TimeoutError,
        Faraday::ConnectionFailed,
        Net::ReadTimeout
      ].freeze

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

        # Intentionally excludes voice. Router#classify consults effective_text
        # unconditionally at the top of the method, BEFORE it reaches the voice?
        # check. If media? included voice, effective_text would resolve to the
        # voice note's caption, and a captioned voice note could misroute
        # through slash-command matching before the voice branch is ever
        # reached. (Voice notes can carry a caption; this guard does not rely on
        # their absence.)
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
      class MarkdownV2SplitError < Hive::Error; end

      attr_reader :client

      # `now:` only seeds the clock of the default `poll_health:` collaborator;
      # Telegram never stores or reads it directly. Inject a fully-built
      # `poll_health:` to govern health tracking (and its clock) explicitly.
      def initialize(token:, logger:, client: nil, base_url: "https://api.telegram.org",
                     http_client: nil, now: -> { Time.now }, poll_health: PollHealth.new(now: now))
        @token = token
        @base_url = base_url.to_s.delete_suffix("/")
        @http_client = http_client
        @logger = logger
        @client = client || ::Telegram::Bot::Client.new(token)
        @poll_health = poll_health
        @build_update_error_classes_seen = {}
      end

      def poll_updates(timeout:, since_update_id:)
        params = { timeout: timeout }
        params[:offset] = since_update_id if since_update_id
        raw_updates = client.api.get_updates(params)
        @poll_health.record_success
        Array(raw_updates).filter_map { |raw| build_update(raw) }
      rescue *BENIGN_POLL_ERRORS => e
        @logger.event(:poll_failure, level: :debug, category: Logger::CATEGORY_NOISE,
                                     error_class: e.class.name, message: e.message)
        emit_poll_unhealthy_if_needed
        []
      rescue StandardError => e
        @logger.event(:poll_failure, error_class: e.class.name, message: e.message)
        emit_poll_unhealthy_if_needed
        []
      end

      # Public view of how `send_message` would split `text` into
      # Telegram-sized chunks, so callers that need per-chunk delivery
      # visibility (e.g. the digest sender) can drive the loop themselves.
      def message_chunks(text, parse_mode: nil)
        split_message(text, parse_mode: parse_mode)
      end

      # Convert one already-validated MarkdownV2 chunk to equivalent HTML.
      # Digest delivery uses this only as a single bounded fallback after
      # Telegram itself rejects a locally valid MarkdownV2 chunk.
      def markdown_v2_to_html(text)
        validate_markdown_v2!(text)
        markdown_v2_html(text)
      end

      def send_message(chat_id:, text:, reply_markup: nil, parse_mode: nil)
        chunks = split_message(text, parse_mode: parse_mode)
        chunks.map.with_index do |chunk, idx|
          send_message_chunk(
            chat_id: chat_id,
            text: chunk,
            parse_mode: parse_mode,
            reply_markup: idx == chunks.length - 1 ? reply_markup : nil
          )
        end
      end

      # Send exactly one already-sized message. Digest delivery checkpoints
      # map one durable unit to one Telegram API call, so they must bypass the
      # generic splitter (especially after MarkdownV2 expands into HTML tags).
      def send_message_chunk(chat_id:, text:, reply_markup: nil, parse_mode: nil)
        params = { chat_id: chat_id, text: text }
        params[:parse_mode] = parse_mode_value(parse_mode) if parse_mode
        params[:reply_markup] = inline_keyboard(reply_markup) if reply_markup
        client.api.send_message(params)
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
        # Intentionally does NOT call emit_poll_unhealthy_if_needed (unlike the
        # two poll_updates rescues): a per-update parse failure occurs AFTER a
        # successful get_updates fetch, so it must not count toward poll-health
        # or trip the outage escalator.
        already_seen = @build_update_error_classes_seen.key?(e.class)
        @build_update_error_classes_seen[e.class] = true
        attrs = { error_class: e.class.name, message: e.message }
        attrs[:backtrace] = Array(e.backtrace).first(10).join("\n") unless already_seen
        @logger.event(:poll_failure, **attrs)
        nil
      end

      def emit_poll_unhealthy_if_needed
        result = @poll_health.record_failure
        return unless result.escalate?

        @logger.event(:poll_unhealthy, level: :warn,
                                       consecutive_failures: result.consecutive_failures,
                                       seconds_since_success: result.seconds_since_success,
                                       reason: result.reason.to_s)
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

      def split_message(text, parse_mode: nil)
        body = text.to_s
        return [ "" ] if body.empty?
        return split_markdown_v2_message(body) if parse_mode.to_s.casecmp?("markdown_v2")

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

      # MarkdownV2 entities are local to one Telegram message. Splitting an
      # open `*bold*`, `_italic_`, code span, or link across two API calls
      # makes both chunks invalid even when the original body is valid.
      # Prefer a balanced newline; if none exists, use the last balanced
      # character boundary at or below Telegram's limit.
      def split_markdown_v2_message(body)
        chunks = []
        remaining = body.dup
        while remaining.length > MAX_MESSAGE_CHARS
          boundary = markdown_v2_boundary(remaining, MAX_MESSAGE_CHARS)
          unless boundary
            raise MarkdownV2SplitError,
                  "MarkdownV2 entity exceeds Telegram's #{MAX_MESSAGE_CHARS}-character limit"
          end

          chunks << remaining[0, boundary.fetch(:cut)]
          remaining = remaining[boundary.fetch(:consume)..] || ""
        end
        validate_markdown_v2!(remaining)
        chunks << remaining unless remaining.empty?
        chunks
      end

      def markdown_v2_boundary(text, limit)
        scan = scan_markdown_v2(text, limit: limit, require_complete: false)
        scan.fetch(:newline) || scan.fetch(:balanced)
      end

      def validate_markdown_v2!(text)
        scan_markdown_v2(text, limit: text.length, require_complete: true)
      end

      # Returns the latest independently valid boundary in the scanned prefix.
      # This is deliberately a small Telegram MarkdownV2 scanner rather than a
      # general Markdown parser: Telegram's grammar and escape rules differ
      # from CommonMark, especially inside code and link targets.
      def scan_markdown_v2(text, limit:, require_complete:)
        stack = []
        balanced = nil
        newline = nil
        index = 0

        while index < limit
          start = index
          top = stack.last

          if top == :pre
            if text[index, 3] == "```" && index + 3 <= limit
              stack.pop
              index += 3
            elsif text[index] == "\\"
              index = consume_markdown_escape(text, index, limit, require_complete)
              break unless index
            else
              index += 1
            end
          elsif top == :code
            if text[index] == "`"
              stack.pop
              index += 1
            elsif text[index] == "\\"
              index = consume_markdown_escape(text, index, limit, require_complete)
              break unless index
            else
              index += 1
            end
          elsif top == :link_target
            if text[index] == "\\"
              index = consume_markdown_escape(text, index, limit, require_complete)
              break unless index
            elsif text[index] == ")"
              stack.pop
              index += 1
            else
              index += 1
            end
          elsif text[index] == "\\"
            index = consume_markdown_escape(text, index, limit, require_complete)
            break unless index
          elsif text[index, 3] == "```" && index + 3 <= limit
            push_markdown_entity!(stack, :pre)
            index += 3
          elsif text[index] == "`"
            push_markdown_entity!(stack, :code)
            index += 1
          elsif text[index, 2] == "![" && index + 2 <= limit
            stack << :link_label
            index += 2
          elsif text[index] == "["
            stack << :link_label
            index += 1
          elsif text[index, 2] == "](" && index + 2 <= limit
            unless stack.last == :link_label
              invalid_markdown_v2!("link label closes out of order", index)
            end

            stack[-1] = :link_target
            index += 2
          elsif text[index] == "]" || text[index] == "(" || text[index] == ")"
            invalid_markdown_v2!("unescaped #{text[index].inspect}", index)
          elsif text[index, 2] == "__" && index + 2 <= limit
            toggle_markdown_entity!(stack, :underline, index)
            index += 2
          elsif text[index, 2] == "||" && index + 2 <= limit
            toggle_markdown_entity!(stack, :spoiler, index)
            index += 2
          elsif text[index] == "*"
            toggle_markdown_entity!(stack, :bold, index)
            index += 1
          elsif text[index] == "_"
            toggle_markdown_entity!(stack, :italic, index)
            index += 1
          elsif text[index] == "~"
            toggle_markdown_entity!(stack, :strikethrough, index)
            index += 1
          elsif text[index] == ">" && markdown_line_start?(text, index)
            index += 1
          elsif MARKDOWN_V2_RESERVED.include?(text[index])
            invalid_markdown_v2!("unescaped #{text[index].inspect}", index)
          else
            index += 1
          end

          next unless stack.empty?

          balanced = { cut: index, consume: index }
          newline = { cut: start, consume: index } if text[start] == "\n"
        end

        if require_complete && (!stack.empty? || index != limit)
          detail = stack.empty? ? "dangling escape" : "unclosed #{stack.last}"
          invalid_markdown_v2!(detail, index)
        end

        { balanced: balanced, newline: newline }
      end

      def consume_markdown_escape(text, index, limit, require_complete)
        return index + 2 if index + 2 <= limit
        invalid_markdown_v2!("dangling escape", index) if require_complete

        nil
      end

      def toggle_markdown_entity!(stack, entity, index)
        if stack.last == entity
          stack.pop
        elsif stack.include?(entity)
          invalid_markdown_v2!("#{entity} closes out of order", index)
        else
          push_markdown_entity!(stack, entity)
        end
      end

      def push_markdown_entity!(stack, entity)
        if %i[pre code].include?(entity) && !stack.empty?
          invalid_markdown_v2!("#{entity} cannot be nested", 0)
        end

        stack << entity
      end

      def markdown_line_start?(text, index)
        index.zero? || text[index - 1] == "\n"
      end

      def invalid_markdown_v2!(detail, index)
        raise MarkdownV2SplitError, "invalid MarkdownV2 at character #{index}: #{detail}"
      end

      def markdown_v2_html(text)
        output = +""
        stack = []
        index = 0
        while index < text.length
          entity = stack.last&.fetch(:entity)
          if entity == :pre
            if text[index, 3] == "```"
              output << "</pre>"
              stack.pop
              index += 3
            else
              index = append_html_character(output, text, index)
            end
          elsif entity == :code
            if text[index] == "`"
              output << "</code>"
              stack.pop
              index += 1
            else
              index = append_html_character(output, text, index)
            end
          elsif text[index] == "\\"
            output << CGI.escapeHTML(text[index + 1])
            index += 2
          elsif text[index, 3] == "```"
            output << "<pre>"
            stack << { entity: :pre }
            index += 3
          elsif text[index] == "`"
            output << "<code>"
            stack << { entity: :code }
            index += 1
          elsif text[index, 2] == "!["
            stack << { entity: :link_label, output_start: output.length }
            index += 2
          elsif text[index] == "["
            stack << { entity: :link_label, output_start: output.length }
            index += 1
          elsif text[index, 2] == "]("
            link = stack.pop
            target_end = markdown_link_target_end(text, index + 2)
            target = unescape_markdown_v2(text[(index + 2)...target_end])
            label = output.slice!(link.fetch(:output_start)..) || ""
            output << %(<a href="#{CGI.escapeHTML(target)}">#{label}</a>)
            index = target_end + 1
          elsif text[index, 2] == "__"
            toggle_html_entity!(output, stack, :underline, "u")
            index += 2
          elsif text[index, 2] == "||"
            toggle_html_entity!(output, stack, :spoiler, "tg-spoiler")
            index += 2
          elsif text[index] == "*"
            toggle_html_entity!(output, stack, :bold, "b")
            index += 1
          elsif text[index] == "_"
            toggle_html_entity!(output, stack, :italic, "i")
            index += 1
          elsif text[index] == "~"
            toggle_html_entity!(output, stack, :strikethrough, "s")
            index += 1
          elsif text[index] == ">" && markdown_line_start?(text, index)
            # Digest rendering does not emit blockquotes. Preserve the glyph
            # as text if a generic caller supplies one.
            output << "&gt;"
            index += 1
          else
            output << CGI.escapeHTML(text[index])
            index += 1
          end
        end
        output
      end

      def append_html_character(output, text, index)
        if text[index] == "\\"
          output << CGI.escapeHTML(text[index + 1])
          index + 2
        else
          output << CGI.escapeHTML(text[index])
          index + 1
        end
      end

      def toggle_html_entity!(output, stack, entity, tag)
        if stack.last&.fetch(:entity) == entity
          output << "</#{tag}>"
          stack.pop
        else
          output << "<#{tag}>"
          stack << { entity: entity }
        end
      end

      def markdown_link_target_end(text, start)
        index = start
        loop do
          if text[index] == "\\"
            index += 2
          elsif text[index] == ")"
            return index
          else
            index += 1
          end
        end
      end

      def unescape_markdown_v2(text)
        text.gsub(/\\(.)/m, '\1')
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
