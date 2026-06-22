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

        result = body.fetch("result", body)
        raise_tool_error(name, result)
        result
      end

      private

      def request(req)
        Hive::Screenote::Http.request(http: @http, request: req, uri: resource, context: "Screenote MCP request")
      end

      # A 2xx JSON-RPC reply can still carry a *tool* failure on the MCP tool
      # channel: `result` is `{"isError":true,"content":[{"text":"…"}]}` for a
      # bad scope, an invalid project_id, a 60/min rate-limit, a 5xx, or a
      # server-side upload failure. Only `body["error"]` (the protocol channel)
      # was inspected, so for `list_projects` the error text fell through
      # `extract_projects` to `[]` and `connect` raised the wrong remedy
      # ("create a project and reconnect"), while `create_screenshot_upload`
      # read a failed upload as success. Surface the tool error as a typed
      # Hive::Error with the joined `content` text.
      def raise_tool_error(name, result)
        return unless result.is_a?(Hash) && result["isError"]

        text = Array(result["content"]).filter_map do |entry|
          entry["text"].to_s if entry.is_a?(Hash) && !entry["text"].to_s.strip.empty?
        end.join("\n").strip
        detail = text.empty? ? "tool reported an error" : text
        raise Hive::Error, "Screenote MCP #{name} failed: #{detail}"
      end

      def parse_response(response, context)
        Hive::Screenote::Http.parse_json_object(unframe_sse(response.body.to_s), context)
      end

      # A Streamable-HTTP MCP endpoint may answer a POST with a bare JSON
      # object OR a `text/event-stream` body (`event: message\ndata: {…}`) —
      # the spec lets the server pick either even though we advertise both, so
      # a flat JSON.parse failed a spec-compliant SSE reply as "unparseable
      # response" and broke every `list_projects`. Concatenate the `data:`
      # payload(s) so an SSE reply parses; a non-SSE body passes through
      # untouched.
      def unframe_sse(body)
        return body unless body.lstrip.start_with?("event:", "data:", "id:", "retry:", ":")

        data = body.each_line.filter_map do |line|
          next unless line.start_with?("data:")

          line.delete_prefix("data:").sub(/\A[ \t]/, "").chomp
        end
        data.empty? ? body : data.join("\n")
      end

      def extract_projects(result)
        # A non-Hash `result` (e.g. a `{"result":[…]}` array) would make
        # `result["projects"]` raise an untyped TypeError; degrade to the
        # documented empty-projects path instead.
        return [] unless result.is_a?(Hash)

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
