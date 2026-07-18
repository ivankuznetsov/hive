require "hive/agent_skills/adapters/base"

module Hive
  module AgentSkills
    module Adapters
      class Pi < Base
        AGENT = "pi"

        protected

        def operations_for_package(package, native_spec, rows)
          state = package_state(rows)
          bin = state.fetch("bin")
          installed = state["package"]
          kind = installed ? "package_update" : "package_install"
          verb = installed ? "update" : "install"
          operation = operation(
            package: package,
            rows: rows,
            kind: kind,
            argv: [ bin, verb, native_spec.source ],
            files: [ config_root(native_spec) ]
          )
          [ operation ]
        end
      end
    end
  end
end
