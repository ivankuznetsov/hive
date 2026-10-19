require "json"

module Hive
  module Mcp
    # Newline-delimited JSON-RPC for the MCP stdio transport. One message is
    # one line; tool text may contain newlines because JSON encoding escapes
    # them. Diagnostics stay on stderr so a client never parses them as RPC.
    module Protocol
      PARSE_ERROR = -32_700
      INVALID_REQUEST = -32_600
      METHOD_NOT_FOUND = -32_601
      INVALID_PARAMS = -32_602
      INTERNAL_ERROR = -32_603

      module_function

      def read_message(line)
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end

      def request?(message)
        message.is_a?(Hash) && message["jsonrpc"] == "2.0" && message.key?("id") &&
          !message["method"].to_s.start_with?("notifications/")
      end

      def notification?(message)
        message.is_a?(Hash) && message["jsonrpc"] == "2.0" &&
          message["method"].is_a?(String) && !request?(message)
      end

      def encode(message)
        JSON.generate(message)
      end
    end
  end
end
