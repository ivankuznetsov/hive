require "hive/mcp"

# Pi MCP renderer. `--no-mcp` (pi >= 1.0.4, Hive's floor) drops the
# personal and project servers. Pi reads servers only from its agent dir,
# which also holds its login, so Hive cannot hand it an explicit server set:
# granted servers are dropped with a notice.
module Hive::AgentSupport::Pi::Mcp
  module_function

  def prepare(policy:, cwd:, version: nil, profile: nil)
    notices = policy.notices.dup
    unless policy.servers.empty?
      notices << "MCP server(s) #{policy.servers.map(&:name).join(', ')} not rendered: " \
                 "Pi cannot receive Hive-granted servers"
    end
    Hive::Mcp.launch(arguments: [ "--no-mcp" ], isolation: :isolated, notices: notices)
  end
end
