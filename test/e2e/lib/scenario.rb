module Hive
  module E2E
    Scenario = Data.define(
      :name, :description, :tags, :setup, :steps, :path,
      :incident_id, :sibling_task_id, :pending, :coverage
    ) do
      def initialize(name:, description:, tags:, setup:, steps:, path:,
                     incident_id: nil, sibling_task_id: nil, pending: false,
                     coverage: Coverage.new(primary: nil, supporting: []).freeze)
        super
      end
    end
    Coverage = Data.define(:primary, :supporting)
    Step = Data.define(:kind, :args, :description, :position)
  end
end
