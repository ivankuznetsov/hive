require "hive/mcp/protocol"
require "hive/mcp/dispatcher"
require "hive/version"

module Hive
  module Mcp
    # stdio MCP server used by the Grok plugin. The process speaks JSON-RPC on
    # stdout and leaves Hive command diagnostics on stderr.
    class Server
      PROTOCOL_VERSIONS = %w[2025-06-18 2025-03-26 2024-11-05].freeze
      INSTRUCTIONS = <<~TEXT.tr("\n", " ").strip
        Hive MCP connector. Call status before claiming task state or acting.
        task reads one task. doctor is read-only. answer_inventory lists
        brainstorm slots and bindings; answer_write submits one final answer
        for a binding from that inventory and does not advance the task. act
        accepts only workflow.advance or workflow.retry, with project:slug and
        the observation token copied from the same status snapshot. This
        process is not a shell. Daily digest reads stay on hive digest --json
        and are not tools here.
      TEXT

      def initialize(input:, output:, dispatcher: Dispatcher.new, version: Hive::VERSION)
        @input = input
        @output = output
        @dispatcher = dispatcher
        @version = version
      end

      def run
        while (line = @input.gets)
          handle_line(line)
        end
      end

      def handle_line(line)
        stripped = line.to_s.strip
        return if stripped.empty?

        message = Protocol.read_message(stripped)
        unless message
          write_error(nil, Protocol::PARSE_ERROR, "parse error")
          return
        end
        return if Protocol.notification?(message)
        unless Protocol.request?(message)
          write_error(message.is_a?(Hash) ? message["id"] : nil, Protocol::INVALID_REQUEST, "invalid request")
          return
        end

        dispatch(message["id"], message["method"].to_s, message["params"])
      rescue StandardError => error
        warn "hive mcp: #{error.class}: #{error.message}"
        write_error(nil, Protocol::INTERNAL_ERROR, "internal error")
      end

      private

      def dispatch(id, method, params)
        case method
        when "initialize" then initialize_result(id, params)
        when "ping" then write_result(id, {})
        when "tools/list" then write_result(id, { "tools" => @dispatcher.catalog })
        when "tools/call" then call_tool(id, params)
        else write_error(id, Protocol::METHOD_NOT_FOUND, "method not found")
        end
      end

      def initialize_result(id, params)
        params = {} unless params.is_a?(Hash)
        requested = params["protocolVersion"].to_s
        version = PROTOCOL_VERSIONS.include?(requested) ? requested : PROTOCOL_VERSIONS.first
        write_result(id, {
          "protocolVersion" => version,
          "capabilities" => { "tools" => { "listChanged" => false } },
          "serverInfo" => { "name" => "hive", "version" => @version },
          "instructions" => INSTRUCTIONS
        })
      end

      def call_tool(id, params)
        unless params.is_a?(Hash) && params["name"].is_a?(String)
          write_error(id, Protocol::INVALID_PARAMS, "tools/call requires a name")
          return
        end

        outcome = @dispatcher.call(params["name"], params["arguments"])
        write_result(id, {
          "content" => [ { "type" => "text", "text" => outcome.fetch(:text).to_s } ],
          "isError" => outcome.fetch(:is_error) == true
        })
      rescue Dispatcher::UnknownTool, Dispatcher::InvalidArguments => error
        write_error(id, Protocol::INVALID_PARAMS, error.message)
      end

      def write_result(id, result)
        write({ "jsonrpc" => "2.0", "id" => id, "result" => result })
      end

      def write_error(id, code, message)
        write({
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => { "code" => code, "message" => message }
        })
      end

      def write(message)
        @output.puts(Protocol.encode(message))
        @output.flush
      end
    end
  end
end
