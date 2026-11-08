require "hive/mcp"
require "hive/mcp/discovery"

# Grok MCP facet. Grok has no flag to ignore its own MCP config (personal,
# project, and Claude/Cursor compat sources), so a Grok launch keeps them and
# receives no Hive grants; `hive doctor` warns. Discovery reads
# `$GROK_HOME/config.toml` for `hive mcp import`.
module Hive::AgentSupport::Grok::Mcp
  Discovery = Hive::Mcp::Discovery
  ISOLATES = false
  ACCEPTS_GRANTS = false

  module_function

  def prepare(policy:, cwd:, version: nil, profile: nil)
    Hive::Mcp.launch(
      isolation: :none,
      notices: policy.notices + [
        "MCP isolation incomplete: Grok has no flag to ignore its own MCP config" \
        "#{Hive::Mcp.skipped_suffix(policy.servers)}"
      ]
    )
  end

  def discover(home:, env:, **)
    grok_home = env["GROK_HOME"].to_s
    grok_home = File.join(home, ".grok") if grok_home.empty?
    path = File.join(grok_home, "config.toml")
    return [] unless File.exist?(path)
    raise Discovery::Skipped, "#{path} is not readable" unless File.readable?(path)

    user_config = Hive::AgentSupport.for(:codex)::UserConfig
    document = user_config.load(path)
    document.tables_under("mcp_servers").filter_map do |table_path, values|
      next unless table_path.length == 2

      name = table_path.last
      raw = {
        "url" => user_config.string(values["url"]), "command" => user_config.string(values["command"]),
        "args" => Discovery.toml_array(values["args"]), "env" => Discovery.toml_table(values["env"]),
        "headers" => Discovery.toml_table(values["http_headers"]),
        "bearer_token_env" => user_config.string(values["bearer_token_env_var"])
      }.compact
      if raw.values.any?(:invalid)
        next Discovery.refused(name, "grok", "its config.toml entry uses values Hive cannot read")
      end

      Discovery.candidate(name, "grok", raw, oauth: false, logged_in: false)
    end
  end
end
