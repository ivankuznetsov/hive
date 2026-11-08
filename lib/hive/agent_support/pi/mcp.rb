require "hive/mcp"
require "hive/mcp/discovery"

# Pi MCP renderer. `--no-mcp` (pi >= 1.0.4, Hive's floor) drops the
# personal and project servers. Pi reads servers only from its agent dir,
# which also holds its login, so Hive cannot hand it an explicit server set:
# granted servers are dropped with a notice.
module Hive::AgentSupport::Pi::Mcp
  Discovery = Hive::Mcp::Discovery
  ISOLATES = true
  ACCEPTS_GRANTS = false

  module_function

  def prepare(policy:, cwd:, version: nil, profile: nil)
    notices = policy.notices.dup
    unless policy.servers.empty?
      notices << "MCP server(s) #{policy.servers.map(&:name).join(', ')} not rendered: " \
                 "Pi cannot receive Hive-granted servers"
    end
    Hive::Mcp.launch(arguments: [ "--no-mcp" ], isolation: :isolated, notices: notices)
  end

  def discover(cwd:, home:, env:, **)
    agent_dir = env["PI_CODING_AGENT_DIR"].to_s
    agent_dir = File.join(home, ".pi", "agent") if agent_dir.empty?
    servers = Discovery.hash_at(Discovery.read_json(File.join(agent_dir, "mcp.json"), "pi") || {}, "mcpServers")
    project = Discovery.hash_at(Discovery.read_json(File.join(cwd, ".pi", "mcp.json"), "pi") || {}, "mcpServers")
    # A project entry without command/url/type only toggles a user server.
    project.each { |name, entry| servers[name] = entry if entry.is_a?(Hash) && (entry.keys & %w[command url type]).any? }
    logins = (Discovery.read_json(File.join(agent_dir, "mcp-auth.json"), "pi") || {}).keys
    servers.map do |name, entry|
      next Discovery.refused(name, "pi", "its entry is not an object") unless entry.is_a?(Hash)

      logged_in = logins.any? { |key| key == name || key.start_with?("#{name}|", "#{name}:") }
      Discovery.candidate(name, "pi", entry.slice("url", "headers", "command", "args", "env", "cwd"),
                oauth: entry.key?("oauth") || logged_in, logged_in: logged_in)
    end
  end
end
