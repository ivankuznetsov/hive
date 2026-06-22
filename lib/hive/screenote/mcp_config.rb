require "fileutils"
require "json"
require "securerandom"
require "hive"
require "hive/paths"

module Hive
  module Screenote
    class McpConfig
      SERVER_NAME = "screenote".freeze
      TOOL_NAMES = %w[
        mcp__screenote__list_projects
        mcp__screenote__create_screenshot_upload
        mcp__screenote__create_screenshot
        mcp__screenote__create_multi_viewport_screenshot
      ].freeze

      attr_reader :credential

      def initialize(credential:)
        @credential = credential
      end

      def self.allowed_tools_csv(base_tools)
        (base_tools.to_s.split(",") + TOOL_NAMES).map(&:strip).reject(&:empty?).uniq.join(",")
      end

      def payload
        token = required("access_token")
        resource = required("mcp_resource")
        {
          "mcpServers" => {
            SERVER_NAME => {
              "type" => "http",
              "url" => resource,
              "headers" => {
                "Authorization" => "Bearer #{token}"
              }
            }
          }
        }
      end

      def write!
        dir = File.join(Hive::Paths.cache_home, "mcp")
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "screenote-#{Process.pid}-#{SecureRandom.hex(8)}.json")
        File.write(path, "#{JSON.pretty_generate(payload)}\n", mode: "w", perm: 0o600)
        File.chmod(0o600, path)
        path
      end

      private

      def required(key)
        value = credential[key].to_s
        raise Hive::ConfigError, "screenote credential missing #{key}" if value.strip.empty?

        value
      end
    end
  end
end
