require "hive/config"
require "hive/mcp/discovery"
require "hive/mcp/importer"

module Hive
  module Mcp
    # `hive setup` and `hive init` ask once, in a terminal, whether to copy
    # the personal MCP servers Hive agents no longer load into the catalog.
    # The question is recorded as `mcp.import_offered` whatever the answer.
    module ImportOffer
      module_function

      def run(cwd:, input:, output:, error:, discover: ->(dir) { Hive::Mcp::Discovery.discover(cwd: dir) })
        return false if Hive::Config.load_global_mcp["import_offered"]

        rows = Hive::Mcp::Importer.plan(discover.call(cwd), Hive::Config.load_global_mcp.fetch("servers"))
        fresh = rows.count { |row| row.status == "new" }
        return false if fresh.zero?

        error.print "Found #{fresh} personal MCP server(s) that Hive-launched agents no longer load. " \
                    "Import them into Hive's catalog now? [y/N]: "
        error.flush
        accepted = %w[y yes].include?(input.gets.to_s.strip.downcase)
        Hive::Mcp::Importer.mark_offered!
        error.puts "Run `hive mcp import` any time to import them." unless accepted
        return false unless accepted

        require "hive/commands/mcp"
        Hive::Commands::Mcp.new("import", cwd: cwd, input: input, output: output, error: error).call
        true
      rescue Hive::Error => e
        error.puts "hive: skipped the MCP import offer (#{e.message}); run `hive mcp import` later"
        false
      end
    end
  end
end
