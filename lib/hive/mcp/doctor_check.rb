require "hive/config"
require "hive/mcp"
require "hive/mcp/discovery"
require "hive/mcp/importer"

module Hive
  module Mcp
    # `hive doctor` rows for Hive-owned MCP (plan 2026-10-15-001, U6). Every
    # row fits the hive-doctor.v2 LegacyCheck shape; warnings never change
    # the exit code. Env vars are reported by name, never by value.
    module DoctorCheck
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
          return [ warning("mcp/inherit", "hive", "mcp.inherit_user", "inherit_user",
                           "mcp.inherit_user is true: isolation is off and agents load their own MCP config") ]
        end

        rows = grant_rows(config, environment) + adapter_rows(environment)
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
          adapter = Hive::Mcp.adapter(agent)
          unless adapter&.const_get(:ISOLATES)
            rows << warning("mcp/isolation", agent, scope, "isolation",
                            "#{agent} runs #{scope} without MCP isolation: it keeps its own MCP config")
          end
          next if policy.servers.empty?

          unless adapter&.const_get(:ACCEPTS_GRANTS)
            rows << warning("mcp/grants", agent, scope, policy.servers.map(&:name).join(","),
                            "#{agent} runs #{scope} and cannot receive Hive-granted servers; they are dropped at launch")
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

      # Agent-specific informational rows, such as the Codex settings every
      # launch carries over.
      def adapter_rows(environment)
        Hive::Mcp::Discovery::AGENTS.flat_map do |agent|
          adapter = Hive::Mcp.adapter(agent)
          adapter.respond_to?(:doctor_rows) ? adapter.doctor_rows(environment) : []
        end
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
      private_class_method :grant_rows, :adapter_rows, :discovery_rows, :warning
    end
  end
end
