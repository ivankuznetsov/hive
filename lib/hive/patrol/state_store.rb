require "hive/patrol/feature"
require "hive/patrol/finding"
require "hive/patrol/base_state_store"

module Hive
  module Patrol
    class StateStore < BaseStateStore
      def initialize(project_root)
        super(project_root, state_directory: "patrol", collections: %w[features findings patches reports runs])
      end

      def write_feature(feature)
        write_record("features", feature)
      end

      def write_finding(finding)
        write_record("findings", finding)
      end

      def write_patch(id, data)
        write_json(File.join(root, "patches", "#{id}.json"), data)
      end
    end
  end
end
