require "hive/agent_skills"

module Hive::AgentSupport::Pi
  class SetupAdapter < Hive::AgentSkills::Adapter
    AGENT = "pi"

    protected

    def operations_for_package(package, native_spec, rows)
      state = package_state(rows)
      installed = state["package"]
      operation = operation(
        package: package,
        rows: rows,
        kind: installed ? "package_update" : "package_install",
        argv: [ state.fetch("bin"), installed ? "update" : "install", native_spec.source ],
        files: [ config_root(native_spec) ]
      )
      [ operation ]
    end
  end
end
