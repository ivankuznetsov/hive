require "hive/workflow"
require "hive/workflows/registry"

module HiveWorkflowTestHelper
  # Resolution-only fixture: stages carry just name/index/state_file/kind so
  # tests can exercise descriptor resolution and stage-state lookup. Dispatch-time
  # fields (advance_verb, status_mode, budget_usd, timeout_sec) are intentionally
  # nil — do not reuse this for dispatch/budget/timeout behavior without filling them.
  def research_workflow
    Hive::Workflow.new(
      id: :research,
      stages: [
        Hive::Workflow::Stage.new(name: "intake", index: 1, state_file: "intake.md", kind: :inert),
        Hive::Workflow::Stage.new(name: "gather", index: 2, state_file: "notes.md", kind: :agent),
        Hive::Workflow::Stage.new(name: "report", index: 3, state_file: "report.md", kind: :marker)
      ]
    )
  end

  # Guard-discriminating descriptor for the `:none` entry split at
  # task_action.rb. The entry stage is `:agent` (not inert) and the middle
  # stage is `:inert` but non-entry, so each conjunct of
  # `entry && !terminal && stage.kind == :inert` is exercised in isolation:
  #   - dropping `stage.kind == :inert` would wrongly advance the `:agent` entry,
  #   - dropping `entry` would wrongly advance the inert middle stage.
  # research_workflow can't catch either regression (its only inert stage is the
  # entry, so both conjuncts move together there).
  def agent_entry_workflow
    Hive::Workflow.new(
      id: :agent_entry,
      stages: [
        Hive::Workflow::Stage.new(name: "draft", index: 1, state_file: "draft.md", kind: :agent),
        Hive::Workflow::Stage.new(name: "hold", index: 2, state_file: "hold.md", kind: :inert),
        Hive::Workflow::Stage.new(name: "ship", index: 3, state_file: "ship.md", kind: :marker)
      ]
    )
  end

  # Degenerate single-stage descriptor: its only stage is simultaneously entry
  # and terminal. Used to pin that a markerless inert entry does NOT auto-advance
  # when there is nowhere to advance to.
  def single_stage_workflow
    Hive::Workflow.new(
      id: :single,
      stages: [
        Hive::Workflow::Stage.new(name: "only", index: 1, state_file: "only.md", kind: :inert)
      ]
    )
  end

  def collision_workflow
    Hive::Workflow.new(
      id: :collision,
      stages: [
        Hive::Workflow::Stage.new(name: "inbox", index: 1, state_file: "idea.md", kind: :inert),
        Hive::Workflow::Stage.new(name: "brainstorm", index: 2, state_file: "brainstorm.md", kind: :agent),
        Hive::Workflow::Stage.new(name: "report", index: 3, state_file: "report.md", kind: :agent)
      ]
    )
  end

  def with_registered_workflow(descriptor)
    original_fetch = Hive::Workflows::Registry.method(:fetch)
    Hive::Workflows::Registry.define_singleton_method(:fetch) do |id|
      id == descriptor.id ? descriptor : original_fetch.call(id)
    end
    yield
  ensure
    Hive::Workflows::Registry.define_singleton_method(:fetch, original_fetch) if original_fetch
  end
end
