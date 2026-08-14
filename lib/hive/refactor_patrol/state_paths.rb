module Hive
  module RefactorPatrol
    # JobStore authority is fixed at v4. Released v3 aggregates remain opaque
    # and byte-identical; runtime code never reads or rewrites them. Other
    # Architecture Patrol owners keep their independent paths and versions.
    module StatePaths
      CURRENT_GENERATION = "v4".freeze

      module_function

      def current_root(hive_state_path)
        File.join(
          File.expand_path(hive_state_path), "refactor_patrol",
          CURRENT_GENERATION
        )
      end
    end
  end
end
