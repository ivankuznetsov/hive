module Hive
  Workflow = Data.define(:id, :stages) do
    def initialize(id:, stages:)
      super(id: id, stages: stages.dup.freeze)
    end
  end

  class Workflow
    Stage = Data.define(
      :name,
      :index,
      :state_file,
      :advance_verb,
      :kind,
      :skill,
      :status_mode,
      :budget_usd,
      :timeout_sec,
      :capability
    ) do
      def initialize(name:, index:, state_file:, advance_verb: nil, kind: nil, skill: nil, status_mode: nil, budget_usd: nil, timeout_sec: nil, capability: nil)
        super
      end

      def dir
        "#{index}-#{name}"
      end
    end

    AdvanceVerb = Data.define(:name, :force_source, :interactive) do
      def initialize(name:, force_source: false, interactive: false)
        super
      end
    end
  end
end
