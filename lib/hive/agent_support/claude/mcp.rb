require "hive/mcp"

# Claude MCP renderer: `--strict-mcp-config` drops every personal, project,
# and claude.ai connector server; the per-launch `--mcp-config` file holds
# only the granted ones. Claude keys a saved OAuth login by name, type, url,
# and headers, so an HTTP entry repeats exactly those catalog fields.
# Secrets stay `${VAR}` placeholders that Claude expands from the child env.
module Hive::AgentSupport::Claude::Mcp
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
