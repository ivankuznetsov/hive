module Hive
  Workflow = Data.define(:id, :stages) do
    def initialize(id:, stages:)
      # Shallow dup+freeze: the element Stage objects stay shared with the
      # caller, safe only because Stage is itself frozen. Don't add a mutable
      # field to Stage on the assumption this dup deep-copies — it does not.
      super(id: id, stages: stages.dup.freeze)
    end
  end

  # Reopened (not redefined): nested Stage/AdvanceVerb constants must live in a
  # class body so they resolve as Workflow::Stage — they can't be declared inside
  # the Data.define block above.
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
