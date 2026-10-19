require "hive/mcp/server"

module Hive
  module Commands
    # Long-running stdio server. `--plugin-path` is the only non-serving mode
    # so an operator can point `grok plugin install` at the shipped manifest.
    class Mcp
      def self.plugin_path
        File.expand_path("../../../plugins/grok-hive", __dir__)
      end

      def initialize(input: $stdin, output: $stdout, server: nil)
        @server = server || Hive::Mcp::Server.new(input: input, output: output)
      end

      def call
        @server.run
      end
    end
  end
end
