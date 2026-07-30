module Hive
  module RefactorPatrol
    # Physical generations for Architecture Patrol state. Only JobStore-owned
    # authority uses CURRENT_GENERATION. Manifests, families, reconciler state,
    # results, logs, and runs retain their independent released v2 locations.
    module StatePaths
      RELEASED_GENERATION = "v2".freeze
      CURRENT_GENERATION = "v3".freeze

      module_function

      def generation_root(hive_state_path)
        File.join(File.expand_path(hive_state_path), "refactor_patrol")
      end

      def current_root(hive_state_path)
        File.join(generation_root(hive_state_path), CURRENT_GENERATION)
      end

      def released_root(hive_state_path)
        File.join(
          generation_root(hive_state_path), RELEASED_GENERATION
        )
      end

      def released_jobs_root(hive_state_path)
        File.join(released_root(hive_state_path), "jobs")
      end
    end
  end
end
