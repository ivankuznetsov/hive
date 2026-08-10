require "hive/agent_skills/adapters/base"

module Hive
  module AgentSkills
    module Adapters
      class Grok < Base
        AGENT = "grok"

        protected

        def operations_for_package(package, native_spec, rows)
          state = package_state(rows)
          bin = state.fetch("bin")
          installed = state["package"]
          files = [
            File.join(config_root(native_spec), "config.toml"),
            File.join(config_root(native_spec), "installed-plugins")
          ]

          if installed.nil?
            return [ operation(
              package: package,
              rows: rows,
              kind: "plugin_install",
              argv: [ bin, "plugin", "install", native_spec.source, "--trust" ],
              files: files
            ) ]
          end

          operations = []
          needs_update = rows.any? { |row| row.health == "stale" } ||
            (installed["enabled"] != false && rows.any? { |row| row.resolution["path"].nil? })
          if needs_update
            operations << operation(
              package: package,
              rows: rows,
              kind: "plugin_update",
              argv: [ bin, "plugin", "update", native_spec.package ],
              files: files
            )
          end
          if installed["enabled"] == false
            operations << operation(
              package: package,
              rows: rows,
              kind: "plugin_enable",
              argv: [ bin, "plugin", "enable", native_spec.package ],
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
