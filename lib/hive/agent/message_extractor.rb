require "json"

module Hive
  class Agent
    module MessageExtractor
      class Accumulator
        attr_reader :source

        def initialize(max_bytes:)
          @max_bytes = max_bytes.to_i
          @structured = nil
          @streaming = false
          @plain_tail = +""
          @source = nil
        end

        def truncated? = @source == :structured_truncated

        def observe(data, raw_line: nil)
          message = MessageExtractor.extract(data)
          if message
            if MessageExtractor.streaming_text_event?(data)
              reset_structured_stream unless @streaming
              append_structured(message)
              @streaming = true
            else
              replace_structured(message)
              @streaming = false
            end
          elsif data.nil? && raw_line
            @plain_tail << raw_line
            @plain_tail = @plain_tail.byteslice(-@max_bytes, @max_bytes) || @plain_tail
          end
          message
        end

        def value
          return nil if truncated?
          return @structured unless @structured.nil?

          plain = @plain_tail.strip
          @source = :plain unless plain.empty?
          plain
        end

        private

        def reset_structured_stream
          @structured = +""
          @source = :structured
        end

        def append_structured(message)
          return if truncated?

          remaining = @max_bytes - @structured.bytesize
          return mark_structured_truncated if message.bytesize > remaining

          @structured << message
        end

        def replace_structured(message)
          return mark_structured_truncated if message.bytesize > @max_bytes

          @structured = +message
          @source = :structured
        end

        def mark_structured_truncated
          @structured = nil
          @source = :structured_truncated
        end
      end

      module_function

      def extract(data)
        data = parse_json_line(data) if data.is_a?(String)
        return nil unless data.is_a?(Hash)

        case data["type"]
        when "text"
          text_chunk(data["data"])
        when "result"
          text_value(data["result"])
        when "item.completed"
          item = data["item"]
          return nil unless item.is_a?(Hash)
          return nil unless %w[agent_message message].include?(item["type"])

          text_value(item["text"]) || text_value(item["message"]) || text_from_content(item["content"])
        when "agent_message"
          text_value(data["text"]) || text_value(data["message"]) || text_from_content(data["content"])
        when "assistant"
          message = data["message"]
          return nil unless message.is_a?(Hash)

          text_value(message["text"]) || text_from_content(message["content"])
        else
          nil
        end
      end

      def streaming_text_event?(data)
        data.is_a?(Hash) && data["type"] == "text"
      end

      def parse_json_line(line)
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end

      def text_from_content(content)
        return text_value(content) if content.is_a?(String)
        return nil unless content.is_a?(Array)

        text = content.filter_map do |item|
          next unless item.is_a?(Hash)

          text_value(item["text"]) if %w[text output_text].include?(item["type"])
        end.join("\n\n")
        text.empty? ? nil : text
      end

      def text_value(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def text_chunk(value)
        text = value.to_s
        text.empty? ? nil : text
      end
    end
  end
end
