module Hive
  module RefactorPatrol
    # JobStore authority is fixed at v3. Other Architecture Patrol owners keep
    # their independent paths and versions.
    module StatePaths
      CURRENT_GENERATION = "v3".freeze

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
