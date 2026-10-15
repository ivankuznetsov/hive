require "json"
require "hive/mcp"
require "hive/mcp/discovery"

# OpenCode MCP renderer. OpenCode merges every config layer and has no
# "ignore user config" switch, so isolation enumerates the servers the
# launch would see (`opencode debug config` in the launch cwd starts none)
# and disables each one in the OPENCODE_CONFIG_CONTENT overlay, next to the
# granted servers. Secrets stay `{env:VAR}` references. A failed probe still
# launches, with a notice (plan 2026-10-15-001, D6).
module Hive::AgentSupport::OpenCode::Mcp
  PROBE_TIMEOUT_SECONDS = 15
  Discovery = Hive::Mcp::Discovery
  ISOLATES = true
  ACCEPTS_GRANTS = true

  module_function

  def prepare(policy:, cwd:, profile:, version: nil)
    notices = policy.notices.dup
    servers = Hive::Mcp.signed_in_servers(policy.servers, :opencode, notices)
    isolation = :isolated
    begin
      discovered = enumerate(profile.bin, cwd)
    rescue Hive::AgentError => e
      discovered = []
      isolation = :partial
      notices << "MCP isolation incomplete: #{e.message}; OpenCode keeps its own MCP servers"
    end
    overlay = discovered.to_h { |name| [ name, { "enabled" => false } ] }
    servers.each { |server| overlay[server.name] = entry(server, notices) }
    Hive::Mcp.launch(
      config_overlay: overlay.empty? ? nil : { "mcp" => overlay }, passthrough_env: Hive::Mcp.referenced_env(servers),
      isolation: isolation, notices: notices
    )
  end

  def enumerate(bin, cwd)
    stdout, status = Hive::Mcp.capture([ bin, "debug", "config" ], chdir: cwd, timeout: probe_timeout)
    raise Hive::AgentError, "`opencode debug config` exited #{status.exitstatus}" unless status.success?

    servers = JSON.parse(stdout).fetch("mcp", {})
    raise Hive::AgentError, "`opencode debug config` returned a malformed mcp table" unless servers.is_a?(Hash)

    servers.keys
  rescue JSON::ParserError, TypeError, NoMethodError
    raise Hive::AgentError, "`opencode debug config` returned malformed JSON"
  rescue SystemCallError => e
    raise Hive::AgentError, "`opencode debug config` could not run (#{e.class.name.split('::').last})"
  end

  def discover(cwd:, capture:, **)
    document = Discovery.probe(capture, [ Hive::AgentProfiles.lookup(:opencode).bin, "debug", "config" ], cwd, "opencode")
    servers = document.is_a?(Hash) ? document["mcp"] || {} : nil
    raise Discovery::Skipped, "`opencode debug config` returned no mcp table" unless servers.is_a?(Hash)

    servers.map do |name, entry|
      next Discovery.refused(name, "opencode", "its entry is not an object") unless entry.is_a?(Hash)

      raw = case entry["type"]
      when "remote" then entry.slice("url", "headers")
      when "local"
        command = Array(entry["command"])
        { "command" => command.first, "args" => command.drop(1), "env" => entry["environment"] || {} }
      else next Discovery.refused(name, "opencode", "transport #{entry['type'].inspect} is not supported")
      end
      Discovery.candidate(name, "opencode", raw, oauth: entry.key?("oauth"), logged_in: false)
    end
  end

  def probe_timeout = PROBE_TIMEOUT_SECONDS

  def entry(server, notices)
    if server.transport == :http
      headers = server.headers.merge(server.headers_env.transform_values { |name| "{env:#{name}}" })
      headers["Authorization"] = "Bearer {env:#{server.bearer_token_env}}" if server.bearer_token_env
      return { "type" => "remote", "url" => server.url, "enabled" => true }
        .tap { |out| out["headers"] = headers unless headers.empty? }
    end

    if server.cwd
      notices << "MCP server #{server.name}: OpenCode has no per-server cwd; it starts in the agent's cwd"
    end
    environment = server.env.merge(server.env_from.transform_values { |name| "{env:#{name}}" })
    { "type" => "local", "command" => [ server.command, *server.args ], "enabled" => true }
      .tap { |out| out["environment"] = environment unless environment.empty? }
  end
  private_class_method :enumerate, :entry
end
