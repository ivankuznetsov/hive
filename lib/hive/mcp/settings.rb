require "hive/config"

module Hive
  module Mcp
    # Resolves the MCP servers Hive grants one launch scope (plan
    # 2026-10-15-001, U1). Servers come only from the global catalog
    # (`mcp.servers` in the XDG config.yml); Config validates both layers at
    # load, so resolution only selects, merges, and freezes.
    module Settings
      # One granted catalog server, in the shape the per-provider renderers
      # consume. `transport` is :http (url/headers/OAuth fields) or :stdio
      # (command/args/env/cwd); the other transport's fields are nil or empty.
      # Credential-bearing fields hold env-var NAMES only: `env_from` and
      # `headers_env` map child var / header name to a host env var name, and
      # `bearer_token_env` names the host var holding the bearer token.
      # `oauth_logins` lists the agents holding a saved OAuth login (nil when
      # untracked).
      Server = Data.define(
        :name, :transport, :command, :args, :env, :env_from, :cwd,
        :url, :bearer_token_env, :headers, :headers_env,
        :oauth_resource, :oauth_client_id, :oauth_scopes, :oauth_logins, :imported_from
      )

      # `inherit_user: true` means Hive adds no MCP isolation at all and
      # `servers` is empty. `notices` are launch-log/receipt lines for grants
      # Hive could not honor.
      Policy = Data.define(:inherit_user, :servers, :notices)

      # Background roles whose agents never inherit the project-wide `mcp.use`;
      # they receive servers only from their own block's grant.
      ISOLATED_SCOPES = %w[babysitter patrol refactor_patrol daily_digest].freeze

      module_function

      # `scope` is a config block path such as "execute", "review.fix",
      # "babysitter", or a workflow stage name. The most specific block with
      # an `mcp.use` wins (review.fix, then review); otherwise the project
      # `mcp.use` applies unless the scope's root is isolated.
      def resolve(cfg, scope:)
        scope = scope.to_s
        names = granted_names(cfg, scope)
        project_inherit = project_inherit_user(cfg)

        unless Hive::Config.global_mcp_catalog_readable?
          notices = []
          unless names.empty?
            notices << "MCP isolation incomplete: global config #{Hive::Config.global_config_path} " \
                       "is not readable; granted server(s) #{names.join(', ')} skipped for #{scope}"
          end
          return policy(project_inherit == true, [], notices)
        end

        catalog = Hive::Config.load_global_mcp
        inherit_user = project_inherit.nil? ? catalog.fetch("inherit_user") : project_inherit
        servers = catalog.fetch("servers")
        missing = names - servers.keys
        unless missing.empty?
          raise Hive::ConfigError,
                Hive::Config.mcp_missing_servers_message(missing, "MCP grants for #{scope}")
        end
        return policy(true, [], []) if inherit_user

        notices = []
        granted = names.filter_map do |name|
          spec = servers.fetch(name)
          next server(name, spec) unless spec["enabled"] == false

          notices << "MCP server #{name} granted to #{scope} is disabled in the global catalog; skipped"
          nil
        end
        policy(false, granted, notices)
      end

      def granted_names(cfg, scope)
        parts = scope.split(".")
        parts.length.downto(1) do |depth|
          block = parts.first(depth).reduce(cfg) { |memo, key| memo.is_a?(Hash) ? memo[key] : nil }
          grant = block.is_a?(Hash) ? block["mcp"] : nil
          return grant["use"].uniq if grant.is_a?(Hash) && grant["use"].is_a?(Array)
        end
        return [] if ISOLATED_SCOPES.include?(parts.first)

        Array(cfg.dig("mcp", "use")).uniq
      end

      # Config.load records the raw project value; synthetic configs without
      # that marker treat a present `mcp.inherit_user` as explicit.
      def project_inherit_user(cfg)
        key = Hive::Config::MCP_INHERIT_USER_PROVENANCE_KEY
        return cfg[key] if cfg.key?(key)

        cfg.dig("mcp", "inherit_user")
      end

      def server(name, spec)
        fields = {
          name: name,
          transport: spec.key?("url") ? :http : :stdio,
          command: spec["command"],
          args: spec.fetch("args", []),
          env: spec.fetch("env", {}),
          env_from: spec.fetch("env_from", {}),
          cwd: spec["cwd"],
          url: spec["url"],
          bearer_token_env: spec["bearer_token_env"],
          headers: spec.fetch("headers", {}),
          headers_env: spec.fetch("headers_env", {}),
          oauth_resource: spec["oauth_resource"],
          oauth_client_id: spec["oauth_client_id"],
          oauth_scopes: spec.fetch("oauth_scopes", []),
          oauth_logins: spec["oauth_logins"],
          imported_from: spec["imported_from"]
        }
        Server.new(**fields.transform_values { |value| Hive::Config.deep_freeze(Hive::Config.deep_dup(value)) })
      end

      def policy(inherit_user, servers, notices)
        Policy.new(inherit_user: inherit_user, servers: servers.freeze, notices: notices.freeze)
      end

      private_class_method :granted_names, :project_inherit_user, :server, :policy
    end
  end
end
