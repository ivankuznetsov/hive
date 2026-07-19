require "hive/patrol/feature"
require "hive/patrol/base_state_store"
require "hive/refactor_patrol/thesis"

module Hive
  module RefactorPatrol
    class StateStore < Hive::Patrol::BaseStateStore
      def initialize(project_root)
        super(project_root, state_directory: "refactor_patrol", collections: %w[features theses runs])
      end

      def write_feature(feature)
        write_record("features", feature)
      end

      def write_thesis(thesis)
        write_record("theses", thesis)
      end
    end
  end
end
