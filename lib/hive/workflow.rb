module Hive
  Workflow = Data.define(:id, :stages) do
    def initialize(id:, stages:)
      super(id: id, stages: stages.freeze)
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
        super(
          name: name,
          index: index,
          state_file: state_file,
          advance_verb: advance_verb,
          kind: kind,
          skill: skill,
          status_mode: status_mode,
          budget_usd: budget_usd,
          timeout_sec: timeout_sec,
          capability: capability
        )
      end

      def dir
        "#{index}-#{name}"
      end
    end

    AdvanceVerb = Data.define(:name, :force_source, :interactive) do
      def initialize(name:, force_source: false, interactive: false)
        super(name: name, force_source: force_source, interactive: interactive)
      end
    end
  end
end
