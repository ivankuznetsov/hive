module Hive
  module RefactorPatrol
    # Physical generations for Architecture Patrol state. Only JobStore-owned
    # authority moves to CURRENT_GENERATION in this cutover; manifests,
    # families, reconciler state, results, logs, and runs retain their released
    # v2 locations until their own schema owners intentionally migrate them.
    module StatePaths
      LEGACY_GENERATION = "v2".freeze
      CURRENT_GENERATION = "v3".freeze

      module_function

      def current_root(hive_state_path)
        File.join(
          File.expand_path(hive_state_path),
          "refactor_patrol",
          CURRENT_GENERATION
        )
      end

      def legacy_root(hive_state_path)
        File.join(
          File.expand_path(hive_state_path),
          "refactor_patrol",
          LEGACY_GENERATION
        )
      end
    end
  end
end
