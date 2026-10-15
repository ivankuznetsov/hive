require "hive/config"
require "hive/mcp"
require "hive/mcp/importer"

module Hive
  module Mcp
    # `hive doctor` rows for Hive-owned MCP (plan 2026-10-15-001, U6). Every
    # row fits the hive-doctor.v2 LegacyCheck shape; warnings never change
    # the exit code. Env vars are reported by name, never by value.
    module DoctorCheck
      # Codex settings Hive replays on every `--ignore-user-config` launch.
      CARRIED_CODEX_KEYS = %w[
        model model_reasoning_effort service_tier personality model_provider profile openai_base_url
      ].freeze

      module_function

      # `discover` is nil when the caller skips the (slow, subprocess-based)
      # personal-config comparison.
      def rows(config:, environment:, project_root:, discover: nil)
        unless Hive::Config.global_mcp_catalog_readable?
          return [ warning("mcp/catalog", "hive", "mcp.servers", "catalog",
                           "global config #{Hive::Config.global_config_path} is not readable; " \
                           "granted MCP servers are skipped at launch") ]
        end
        if Hive::Mcp::Settings.resolve(config, scope: "execute").inherit_user
          return [ warning("mcp/isolation", "hive", "mcp.inherit_user", "inherit_user",
                           "mcp.inherit_user is true: isolation is off and agents load their own MCP config") ]
        end

        rows = grant_rows(config, environment) + codex_rows(environment)
        rows.concat(discovery_rows(project_root, discover)) if discover
        rows
      end

      # [scope, agent] for every configured role.
      def roles(config)
        roles = Hive::Config::ROLE_AGENT_PATHS.map do |path|
          [ path[0...-1].join("."), (config.dig(*path) || "claude").to_s ]
        end
        Array(config.dig("review", "reviewers")).each do |spec|
          roles << [ "review", spec["agent"].to_s ] if spec.is_a?(Hash) && spec["agent"]
        end
        roles.uniq
      end

      def grant_rows(config, environment)
        rows = []
        missing_env = []
        roles(config).each do |scope, agent|
          policy = Hive::Mcp::Settings.resolve(config, scope: scope)
          if agent == "grok"
            rows << warning("mcp/grok", "grok", scope, "isolation",
                            "Grok runs #{scope} without MCP isolation: it has no flag to ignore its own MCP config")
          end
          next if policy.servers.empty?

          if agent == "pi"
            rows << warning("mcp/pi", "pi", scope, policy.servers.map(&:name).join(","),
                            "Pi runs #{scope} and cannot receive Hive-granted servers; they are dropped at launch")
          end
          policy.servers.each do |server|
            if Hive::Mcp.oauth?(server) && !Array(server.oauth_logins).include?(agent)
              rows << warning("mcp/login", agent, scope, server.name,
                              "#{server.name} granted to #{scope} but #{agent} has no login; " \
                              "run `hive mcp login #{server.name} --agent #{agent}`")
            end
            missing_env.concat(Hive::Mcp.referenced_env([ server ]).reject { |name| environment.key?(name) }.map { |name| [ server.name, name ] })
          end
        end
        missing_env.uniq.each do |server, name|
          rows << warning("mcp/env", "env", server, name,
                          "#{name} is not set in this shell; MCP server #{server} reads it at launch")
        end
        rows
      end

      def codex_rows(environment)
        user_config = Hive::AgentSupport.for(:codex)::UserConfig
        document = user_config.load(user_config.path(env: environment))
        carried = CARRIED_CODEX_KEYS.select { |key| document[key] } +
                  %w[model_providers profiles].select { |table| document.tables_under(table).any? }
        return [] if carried.empty?

        [ {
          kind: "dependency", stage: "mcp", label: "mcp/codex-config", agent: "codex",
          configured_skill: "config.toml", skill: carried.join(","), status: "present",
          message: "carried over from config.toml on every Hive Codex launch: #{carried.join(', ')}"
        } ]
      end

      def discovery_rows(project_root, discover)
        result = discover.call(project_root)
        planned = Hive::Mcp::Importer.plan(result, Hive::Config.load_global_mcp.fetch("servers"))
        rows = []
        fresh = planned.select { |row| row.status == "new" }
        unless fresh.empty?
          rows << warning("mcp/personal", fresh.flat_map(&:sources).uniq.join(","), "mcp-import",
                          fresh.map(&:name).join(","),
                          "personal MCP servers not in Hive's catalog (agents launched by Hive no longer load them): " \
                          "#{fresh.map(&:name).join(', ')}; run `hive mcp import`")
        end
        planned.select { |row| %w[drift catalog-only].include?(row.status) }.each do |row|
          rows << warning("mcp/drift", row.sources.join(","), "mcp-import", row.name,
                          "catalog entry #{row.name} #{row.status == 'drift' ? 'changed' : 'disappeared'} at its source; " \
                          "run `hive mcp import --only #{row.name} --update` or edit the global config")
        end
        rows
      end

      def warning(label, agent, configured_skill, skill, message)
        {
          kind: "warning", stage: "mcp", label: label, agent: agent, configured_skill: configured_skill,
          skill: skill, status: "warning", message: message
        }
      end
      private_class_method :grant_rows, :codex_rows, :discovery_rows, :warning
    end
  end
end
