require "json"
require "net/http"
require "uri"
require "hive"
require "hive/screenote/http"

module Hive
  module Screenote
    class McpClient
      attr_reader :resource

      def initialize(resource:, access_token:, http: Net::HTTP)
        @resource = URI(resource)
        @access_token = access_token.to_s
        @http = http
        @request_id = 0
      end

      def list_projects
        result = call_tool("list_projects")
        extract_projects(result)
      end

      def call_tool(name, arguments = {})
        @request_id += 1
        req = Net::HTTP::Post.new(resource)
        # MCP Streamable-HTTP servers may reply with either a JSON object or
        # an SSE stream; the spec requires clients to advertise both on POST.
        req["Accept"] = "application/json, text/event-stream"
        req["Authorization"] = "Bearer #{@access_token}"
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(
          jsonrpc: "2.0",
          id: @request_id,
          method: "tools/call",
          params: { name: name, arguments: arguments }
        )
        body = parse_response(request(req), "Screenote MCP #{name}")
        error = body["error"]
        raise Hive::Error, "Screenote MCP #{name} failed: #{error["message"] || error}" if error.is_a?(Hash)

        body.fetch("result", body)
      end

      private

      def request(req)
        Hive::Screenote::Http.request(http: @http, request: req, uri: resource, context: "Screenote MCP request")
      end

      def parse_response(response, context)
        parsed = JSON.parse(response.body.to_s)
        return parsed if parsed.is_a?(Hash)

        raise Hive::Error, "#{context} returned a non-object response"
      rescue JSON::ParserError
        raise Hive::Error, "#{context} returned an unparseable response"
      end

      def extract_projects(result)
        direct = result["projects"]
        return direct if direct.is_a?(Array)

        structured = result["structuredContent"]
        return structured["projects"] if structured.is_a?(Hash) && structured["projects"].is_a?(Array)

        content = Array(result["content"]).find { |entry| entry.is_a?(Hash) && entry["text"].to_s.strip.start_with?("[", "{") }
        return [] unless content

        parsed = JSON.parse(content["text"])
        parsed.is_a?(Hash) ? Array(parsed["projects"]) : Array(parsed)
      rescue JSON::ParserError
        # The text payload LOOKED like JSON (started with `[`/`{`) but did
        # not parse. Swallowing to `[]` here would surface to the operator
        # as the benign "create a project and reconnect" message with the
        # wrong remediation; raise so the real "unparseable" cause shows.
        raise Hive::Error, "Screenote MCP list_projects returned an unparseable projects payload"
      end
    end
  end
end
