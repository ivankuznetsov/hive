require "json"
require "open3"
require "timeout"
require "hive/mcp"

# OpenCode MCP renderer. OpenCode merges every config layer and has no
# "ignore user config" switch, so isolation enumerates the servers the
# launch would see (`opencode debug config` in the launch cwd starts none)
# and disables each one in the OPENCODE_CONFIG_CONTENT overlay, next to the
# granted servers. Secrets stay `{env:VAR}` references. A failed probe still
# launches, with a notice (plan 2026-10-15-001, D6).
module Hive::AgentSupport::OpenCode::Mcp
  PROBE_TIMEOUT_SECONDS = 15

  module_function

  def prepare(policy:, cwd:, profile:, version: nil)
    notices = policy.notices.dup
    servers = Hive::Mcp.signed_in_servers(policy.servers, :opencode, notices)
    isolation = :isolated
    begin
      discovered = discover(profile.bin, cwd)
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

  def discover(bin, cwd)
    stdout, status = capture(bin, cwd)
    raise Hive::AgentError, "`opencode debug config` exited #{status.exitstatus}" unless status.success?

    servers = JSON.parse(stdout).fetch("mcp", {})
    raise Hive::AgentError, "`opencode debug config` returned a malformed mcp table" unless servers.is_a?(Hash)

    servers.keys
  rescue JSON::ParserError, TypeError, NoMethodError
    raise Hive::AgentError, "`opencode debug config` returned malformed JSON"
  rescue SystemCallError => e
    raise Hive::AgentError, "`opencode debug config` could not run (#{e.class.name.split('::').last})"
  end

  def capture(bin, cwd)
    Open3.popen3(bin, "debug", "config", chdir: cwd, pgroup: true) do |stdin, stdout, stderr, waiter|
      stdin.close
      out = Thread.new { stdout.read }
      Thread.new { stderr.read }
      unless waiter.join(probe_timeout)
        Process.kill("KILL", -waiter.pid)
        raise Hive::AgentError, "`opencode debug config` timed out after #{probe_timeout}s"
      end
      [ out.value, waiter.value ]
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
  private_class_method :discover, :capture, :entry
end
