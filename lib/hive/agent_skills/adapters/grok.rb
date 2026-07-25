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

          kind, argv =
            if installed.nil?
              [
                "plugin_install",
                [ bin, "plugin", "install", native_spec.source, "--trust" ]
              ]
            elsif installed["enabled"] == false
              [
                "plugin_enable",
                [ bin, "plugin", "enable", native_spec.package ]
              ]
            elsif rows.any? { |row| row.health == "stale" } ||
                  rows.any? { |row| row.resolution["path"].nil? }
              [
                "plugin_update",
                [ bin, "plugin", "update", native_spec.package ]
              ]
            end
          return [] unless kind

          [ operation(package: package, rows: rows, kind: kind, argv: argv, files: files) ]
        end
      end
    end
  end
end
