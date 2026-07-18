require "hive/agent_skills/adapters/base"

module Hive
  module AgentSkills
    module Adapters
      class Claude < Base
        AGENT = "claude"

        protected

        def operations_for_package(package, native_spec, rows)
          state = package_state(rows)
          bin = state.fetch("bin")
          files = [ File.join(config_root(native_spec), "plugins") ]
          operations = []
          marketplace = state["marketplace"]
          unless marketplace
            operations << operation(
              package: package,
              rows: rows,
              kind: "marketplace_add",
              argv: [ bin, "plugin", "marketplace", "add", native_spec.source, "--scope", native_spec.scope ],
              files: files
            )
          end

          package_entry = state["package"]
          kind = if package_entry.nil?
            "plugin_install"
          elsif rows.any? { |row| row.health == "stale" } || rows.any? { |row| row.resolution["path"].nil? }
            "plugin_update"
          end
          if kind
            verb = kind == "plugin_install" ? "install" : "update"
            operations << operation(
              package: package,
              rows: rows,
              kind: kind,
              argv: [ bin, "plugin", verb, native_spec.package, "--scope", native_spec.scope ],
              files: files,
              depends_on: [ operations.last&.id ]
            )
          end
          operations
        end
      end
    end
  end
end
