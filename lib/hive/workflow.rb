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
    # Soft lookup: returns the Stage or nil so callers can decide how to handle
    # an unknown name (Task#validate_workflow_stage! raises its own message).
    def stage_named(name)
      stages.find { |stage| stage.name == name }
    end

    # Hard resolve: raises KeyError on an unknown name — used where a missing
    # stage is a programmer error, not a recoverable condition.
    def state_file_for(name)
      stage = stage_named(name)
      return stage.state_file if stage

      raise KeyError, "unknown stage #{name.inspect} for workflow #{id.inspect}"
    end

    def stage_names
      # Frozen to match the parallel frozen Task::STAGE_NAMES constant — a
      # uniform immutability contract across both sources of truth. A fresh
      # array is built each call, so freezing it is safe (callers don't mutate).
      stages.map(&:name).freeze
    end

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
