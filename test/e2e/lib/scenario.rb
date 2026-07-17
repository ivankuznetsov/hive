module Hive
  module E2E
    Scenario = Data.define(
      :name, :description, :tags, :setup, :steps, :path,
      :incident_id, :sibling_task_id, :pending
    ) do
      def initialize(name:, description:, tags:, setup:, steps:, path:,
                     incident_id: nil, sibling_task_id: nil, pending: false)
        super
      end
    end
    Step = Data.define(:kind, :args, :description, :position)
  end
end
