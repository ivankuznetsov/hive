require "hive/agent_skills/adapters/base"

module Hive::AgentSupport::Claude
  class SetupAdapter < Hive::AgentSkills::Adapters::Base
    AGENT = "claude"

    protected

    def operations_for_package(package, native_spec, rows)
      state = package_state(rows)
      bin = state.fetch("bin")
      files = [ File.join(config_root(native_spec), "plugins") ]
      operations = []
      unless state["marketplace"]
        operations << operation(
          package:, rows:, kind: "marketplace_add",
          argv: [ bin, "plugin", "marketplace", "add", native_spec.source, "--scope", native_spec.scope ],
          files:
        )
      end

      installed = state["package"]
      kind = if installed.nil?
        "plugin_install"
      elsif rows.any? { |row| row.health == "stale" || row.resolution["path"].nil? }
        "plugin_update"
      end
      if kind
        verb = kind.delete_prefix("plugin_")
        operations << operation(
          package:, rows:, kind:,
          argv: [ bin, "plugin", verb, native_spec.package, "--scope", native_spec.scope ],
          files:, depends_on: [ operations.last&.id ]
        )
      end
      operations
    end
  end
end
