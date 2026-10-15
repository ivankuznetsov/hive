require "fileutils"
require "json"
require "tmpdir"
require "hive/agent_support"
require "hive/atomic_file"
require "hive/mcp/settings"

module Hive
  # Hive-owned MCP for launched agents (plan 2026-10-15-001). A launch starts
  # with no personal or project MCP servers and receives only the servers
  # its scope is granted. `prepare` turns a resolved Settings::Policy into
  # the provider-specific argv/env one launch needs, through the
  # `AgentSupport.for(profile)::Mcp` renderer.
  module Mcp
    # `arguments` append to the trusted argv; `environment` merges into the
    # child env; `passthrough_env` names host vars a rendered server reads
    # (copied from ENV so they survive `unsetenv_others`); `config_overlay`
    # is a provider config fragment (OpenCode). `isolation` is :isolated,
    # :partial (rendered, but a discovery step failed), :none (no renderer),
    # or :inherit (`mcp.inherit_user`). `notices` go to the launch log.
    Launch = Data.define(
      :arguments, :environment, :passthrough_env, :config_overlay,
      :cleanup_paths, :isolation, :notices
    ) do
      def cleanup!
        cleanup_paths.each do |path|
          FileUtils.remove_entry_secure(path)
        rescue Errno::ENOENT
          nil
        end
      end
    end

    EMPTY_POLICY = Settings::Policy.new(inherit_user: false, servers: [].freeze, notices: [].freeze)

    module_function

    # The policy for one launch scope; a cfg-less launch grants nothing.
    def policy(cfg, scope:)
      return EMPTY_POLICY if cfg.nil?

      Settings.resolve(cfg, scope: scope)
    end

    # The config block a task's stage reads its grant from: "4-execute" ->
    # "execute", "5-open-pr" -> "open_pr" (the admitted-route convention).
    def scope_for(stage_name)
      stage_name.to_s.sub(/\A\d+-/, "").tr("-", "_")
    end

    def prepare(profile:, policy:, cwd:, version: nil)
      return launch(isolation: :inherit, notices: policy.notices) if policy.inherit_user

      unless Hive::AgentSupport.supports?(profile, :Mcp)
        name = profile.respond_to?(:name) ? profile.name : profile
        notices = policy.notices + [
          "MCP isolation incomplete: agent #{name} has no Hive MCP renderer, so it keeps its own MCP config" \
          "#{skipped_suffix(policy.servers)}"
        ]
        return launch(isolation: :none, notices: notices)
      end

      Hive::AgentSupport.for(profile)::Mcp.prepare(
        policy: policy, cwd: cwd, version: version, profile: profile
      )
    end

    # Prepare a launch for a direct Hive::Agent caller and remove its
    # rendered files once the block returns.
    def with_launch(profile:, cfg:, scope:, cwd:)
      launch = prepare(profile: profile, policy: policy(cfg, scope: scope), cwd: cwd)
      yield launch
    ensure
      launch&.cleanup!
    end

    def launch(isolation:, arguments: [], environment: {}, passthrough_env: [],
               config_overlay: nil, cleanup_paths: [], notices: [])
      Launch.new(
        arguments: arguments.map { |argument| argument.to_s.dup.freeze }.freeze,
        environment: environment.dup.freeze,
        passthrough_env: passthrough_env.uniq.freeze,
        config_overlay: config_overlay.nil? ? nil : Hive::Config.deep_freeze(config_overlay),
        cleanup_paths: cleanup_paths.dup.freeze,
        isolation: isolation,
        notices: notices.dup.freeze
      )
    end

    # A per-launch 0700 directory for rendered config.
    def private_dir = Dir.mktmpdir("hive-mcp-")

    def write_private_json(path, data)
      Hive::AtomicFile.write(path, JSON.pretty_generate(data), mode: 0o600, fsync: false)
    end

    # Host env var NAMES a server reads; values never enter Hive config,
    # argv, or rendered files.
    def referenced_env(servers)
      servers.flat_map do |server|
        [ server.bearer_token_env, *server.env_from.values, *server.headers_env.values ]
      end.compact.uniq
    end

    # An HTTP server signs in through the agent's own OAuth flow when it
    # carries OAuth fields or a recorded login list; one with a bearer or
    # header credential, or none at all, does not.
    def oauth?(server)
      return false unless server.transport == :http
      return false if server.bearer_token_env || !server.headers_env.empty?

      !server.oauth_logins.nil? || !server.oauth_resource.nil? ||
        !server.oauth_client_id.nil? || !server.oauth_scopes.empty?
    end

    # Logins are per agent: a headless launch cannot run an OAuth browser
    # step, so an OAuth server is rendered only to an agent `hive mcp import`
    # or `hive mcp login` recorded a saved login for. The rest are skipped
    # with a notice.
    def signed_in_servers(servers, agent, notices)
      servers.select do |server|
        next true unless oauth?(server) && !Array(server.oauth_logins).include?(agent.to_s)

        notices << "MCP server #{server.name} skipped: #{agent} has no saved login for it; " \
                   "run `hive mcp login #{server.name} --agent #{agent}`"
        false
      end
    end

    def skipped_suffix(servers)
      return "" if servers.empty?

      "; granted server(s) #{servers.map(&:name).join(', ')} not rendered"
    end
  end
end
