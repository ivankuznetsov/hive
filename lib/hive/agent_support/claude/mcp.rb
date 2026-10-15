require "digest"
require "hive/mcp"
require "hive/mcp/discovery"

# Claude MCP renderer: `--strict-mcp-config` drops every personal, project,
# and claude.ai connector server; the per-launch `--mcp-config` file holds
# only the granted ones. Claude keys a saved OAuth login by name, type, url,
# and headers, so an HTTP entry repeats exactly those catalog fields.
# Secrets stay `${VAR}` placeholders that Claude expands from the child env.
module Hive::AgentSupport::Claude::Mcp
  Discovery = Hive::Mcp::Discovery
  ISOLATES = true
  ACCEPTS_GRANTS = true

  module_function

  def prepare(policy:, cwd:, version: nil, profile: nil)
    notices = policy.notices.dup
    servers = Hive::Mcp.signed_in_servers(policy.servers, :claude, notices)
    dir = Hive::Mcp.private_dir
    path = File.join(dir, "mcp.json")
    Hive::Mcp.write_private_json(path, { "mcpServers" => servers.to_h { |server| [ server.name, entry(server, notices) ] } })
    Hive::Mcp.launch(
      arguments: [ "--strict-mcp-config", "--mcp-config", path ],
      passthrough_env: Hive::Mcp.referenced_env(servers),
      cleanup_paths: [ dir ], isolation: :isolated, notices: notices
    )
  rescue StandardError
    FileUtils.remove_entry_secure(dir) if dir && File.exist?(dir)
    raise
  end

  # User (~/.claude.json), project (.mcp.json) and local
  # (projects[cwd] in ~/.claude.json) scopes; the more specific wins.
  def discover(cwd:, home:, **)
    state = Discovery.read_json(File.join(home, ".claude.json"), "claude") || {}
    servers = {}
    servers.merge!(Discovery.hash_at(state, "mcpServers"))
    servers.merge!(Discovery.hash_at(Discovery.read_json(File.join(cwd, ".mcp.json"), "claude") || {}, "mcpServers"))
    servers.merge!(Discovery.hash_at(Discovery.hash_at(Discovery.hash_at(state, "projects"), cwd), "mcpServers"))
    logins = Discovery.hash_at(Discovery.read_json(File.join(home, ".claude", ".credentials.json"), "claude") || {}, "mcpOAuth").keys
    servers.map do |name, entry|
      next Discovery.refused(name, "claude", "its entry is not an object") unless entry.is_a?(Hash)

      type = entry["type"] || (entry["url"] ? "http" : "stdio")
      next Discovery.refused(name, "claude", "transport #{type.inspect} is not supported") unless %w[http stdio].include?(type)

      raw = entry.slice("url", "headers", "command", "args", "env", "cwd")
      logged_in = type == "http" && logins.include?(login_key(name, entry))
      Discovery.candidate(name, "claude", raw, oauth: logged_in, logged_in: logged_in)
    end
  end

  # Claude keys a saved MCP login by the server name and a hash of its
  # type, url and headers (read from the 2.1.296 bundle; unverified
  # whether `${VAR}` headers are hashed raw or expanded).
  def login_key(name, entry)
    identity = { "type" => entry["type"] || "http", "url" => entry["url"], "headers" => entry["headers"] || {} }
    "#{name}|#{Digest::SHA256.hexdigest(JSON.generate(identity))[0, 16]}"
  end

  # `claude mcp login` finds the server by name in Claude's own config, which
  # must carry the same type, URL and headers (`hive mcp import` keeps them).
  def login_argv(name, _spec) = [ Hive::AgentProfiles.lookup(:claude).bin, "mcp", "login", name ]

  def entry(server, notices)
    return http_entry(server) if server.transport == :http

    if server.cwd
      notices << "MCP server #{server.name}: Claude has no per-server cwd; it starts in the agent's cwd"
    end
    env = server.env.merge(server.env_from.transform_values { |name| "${#{name}}" })
    { "type" => "stdio", "command" => server.command, "args" => server.args }
      .tap { |out| out["env"] = env unless env.empty? }
  end

  def http_entry(server)
    headers = server.headers.merge(server.headers_env.transform_values { |name| "${#{name}}" })
    headers["Authorization"] = "Bearer ${#{server.bearer_token_env}}" if server.bearer_token_env
    { "type" => "http", "url" => server.url }.tap { |out| out["headers"] = headers unless headers.empty? }
  end
  private_class_method :entry, :http_entry
end
