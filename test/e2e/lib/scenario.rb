module Hive
  module E2E
    Scenario = Data.define(:name, :description, :tags, :setup, :steps, :path)
    Step = Data.define(:kind, :args, :description, :position)
  end
end
