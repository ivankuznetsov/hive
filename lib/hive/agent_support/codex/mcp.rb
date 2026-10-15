require "json"
require "hive/mcp"
require "hive/agent_skills/manifest"

# Codex MCP renderer. `--ignore-user-config` drops every personal and
# trusted-project server (`-c mcp_servers={}` cannot: overrides deep-merge),
# and granted servers return as `-c mcp_servers.<name>.*` overrides whose
# credentials are env-var names. Ignoring config.toml also drops personal
# settings, so the launch carries back the model, effort, the OD-A allowlist,
# the OAuth credential store, and the managed-skill plugins the operator has
# enabled (plan 2026-10-15-001). Those carried values are defaults: an
# identity or routing argument for the same key wins.
module Hive::AgentSupport::Codex::Mcp
  # Top-level config.toml keys replayed on every launch. `profile` brings
  # its `profiles.<name>` table and `model_provider` the `model_providers`
  # tables, since either is useless without the other.
  CARRIED_KEYS = %w[
    model_reasoning_effort service_tier personality model_provider profile
    openai_base_url mcp_oauth_credentials_store
  ].freeze
  CARRIED_TABLES = %w[model_providers profiles].freeze
  # Literal credentials in a carried table stay in config.toml: replaying
  # them would put the value in argv.
  SECRET_KEY = /(?:TOKEN|SECRET|PASSWORD|API_?KEY|HEADERS|AUTHORIZATION)/i

  module_function

  def prepare(policy:, cwd:, version: nil, profile: nil, user_config: Hive::AgentSupport::Codex::UserConfig.load)
    notices = policy.notices.dup
    servers = Hive::Mcp.signed_in_servers(policy.servers, :codex, notices)
    environment = {}
    arguments = [ Hive::Mcp::ONCE_FLAG, *plugin_arguments(user_config) ]
    servers.each { |server| arguments.concat(server_arguments(server, environment)) }
    Hive::Mcp.launch(
      arguments: arguments,
      default_arguments: carried_arguments(user_config, notices),
      environment: environment,
      passthrough_env: Hive::Mcp.referenced_env(servers),
      isolation: :isolated, notices: notices
    )
  end

  # Model and the OD-A settings, as overridable `[flag, value]` groups.
  def carried_arguments(config, notices)
    groups = []
    groups << [ "--model", Hive::AgentSupport::Codex::UserConfig.string(config["model"]) ] if config["model"]
    CARRIED_KEYS.each { |key| groups << [ "-c", "#{key}=#{config[key]}" ] if config[key] }
    CARRIED_TABLES.each do |table|
      config.tables_under(table).each do |path, values|
        values.each do |key, raw|
          dotted = [ *path, key ].join(".")
          if key.match?(SECRET_KEY) || path.any? { |segment| segment.match?(SECRET_KEY) }
            notices << "Codex setting #{dotted} not carried over: it may hold a credential; " \
                       "export it through the provider's env_key instead"
            next
          end
          groups << [ "-c", "#{path.map { |segment| toml_key(segment) }.join('.')}.#{toml_key(key)}=#{raw}" ]
        end
      end
    end
    config.skipped.each do |key|
      root = key.split(".").first
      next unless key == "model" || CARRIED_KEYS.include?(key) || CARRIED_TABLES.include?(root)

      notices << "Codex setting #{key} not carried over: Hive reads only single-line config.toml values"
    end
    groups
  end

  # Plugins Hive's managed skills come from, re-enabled when config.toml
  # enables them (`--ignore-user-config` would otherwise hide their skills).
  def plugin_arguments(config)
    managed_plugins.flat_map do |id|
      next [] unless config.table("plugins", id)["enabled"] == "true"

      [ "-c", "plugins.#{id}.enabled=true" ]
    end
  end

  def managed_plugins
    @managed_plugins ||= Hive::AgentSkills::Manifest.load.packages.filter_map do |package|
      native = package.agents["codex"]
      native.package if native.is_a?(Hive::AgentSkills::Manifest::NativePackage)
    end.freeze
  end

  def server_arguments(server, environment)
    fields = if server.transport == :http
      http_fields(server)
    else
      stdio_fields(server, environment)
    end
    fields.compact.flat_map { |key, value| [ "-c", "mcp_servers.#{server.name}.#{key}=#{value}" ] }
  end

  def http_fields(server)
    [
      [ "url", JSON.generate(server.url) ],
      server.bearer_token_env && [ "bearer_token_env_var", JSON.generate(server.bearer_token_env) ],
      server.headers.empty? ? nil : [ "http_headers", inline_table(server.headers) ],
      server.headers_env.empty? ? nil : [ "env_http_headers", inline_table(server.headers_env) ],
      server.oauth_resource && [ "oauth_resource", JSON.generate(server.oauth_resource) ]
    ]
  end

  # Codex forwards host vars only under their own name (`env_vars`), so a
  # renamed `env_from` entry is set in the Codex process env instead of argv.
  def stdio_fields(server, environment)
    forwarded = server.env_from.map do |child, host|
      environment[child] = ENV[host] if child != host && ENV.key?(host)
      child
    end
    [
      [ "command", JSON.generate(server.command) ],
      [ "args", JSON.generate(server.args) ],
      server.env.empty? ? nil : [ "env", inline_table(server.env) ],
      forwarded.empty? ? nil : [ "env_vars", JSON.generate(forwarded) ],
      server.cwd && [ "cwd", JSON.generate(server.cwd) ]
    ]
  end

  def inline_table(hash)
    "{ #{hash.map { |key, value| "#{toml_key(key)} = #{JSON.generate(value)}" }.join(', ')} }"
  end

  def toml_key(key) = key.match?(/\A[A-Za-z0-9_-]+\z/) ? key : JSON.generate(key)
  private_class_method :carried_arguments, :plugin_arguments, :server_arguments, :http_fields,
                       :stdio_fields, :inline_table, :toml_key
end
