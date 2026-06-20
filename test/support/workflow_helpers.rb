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
