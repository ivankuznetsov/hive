require "json"
require "net/http"
require "uri"
require "hive"
require "hive/screenote/oauth_client"

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
        req["Accept"] = "application/json"
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
        response = @http.start(resource.host, resource.port, **http_options) { |http| http.request(req) }
        raise Hive::Error, "Screenote MCP request failed (HTTP #{response.code})" unless response.is_a?(Net::HTTPSuccess)

        response
      rescue *Hive::Screenote::OAuthClient::NETWORK_ERRORS => e
        raise Hive::Error, "Screenote MCP request: could not reach Screenote (#{e.class}: #{e.message})"
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
        []
      end

      def http_options
        {
          use_ssl: resource.scheme == "https",
          open_timeout: Hive::Screenote::OAuthClient::OPEN_TIMEOUT_SEC,
          read_timeout: Hive::Screenote::OAuthClient::READ_TIMEOUT_SEC
        }
      end
    end
  end
end
