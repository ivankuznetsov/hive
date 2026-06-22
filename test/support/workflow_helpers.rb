require "hive/workflow"
require "hive/workflows/registry"
require "hive/stages/base"

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

  # Guard-discriminating descriptor for the `:none` advance gate at
  # task_action.rb (`!terminal && stage.kind == :inert`). The entry stage is
  # `:agent` (not inert) and the middle stage is `:inert` but non-entry, so the
  # two surviving conjuncts are each exercised in isolation:
  #   - the `:agent` ENTRY must RUN — dropping `stage.kind == :inert` would
  #     wrongly advance it.
  #   - the inert NON-entry MIDDLE must ADVANCE — the earlier `entry &&` conjunct
  #     was deliberately dropped (U6.6), because `Resolver.resolve` raises
  #     `StageError` for `kind: :inert`, so routing it to `hive run` would strand
  #     the task (neither runnable nor advanceable).
  # research_workflow can't catch either case (its only inert stage is the entry,
  # so kind and position move together there).
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

  def dispatch_workflow
    Hive::Workflow.new(
      id: :dispatch,
      stages: [
        Hive::Workflow::Stage.new(
          name: "intake",
          index: 1,
          state_file: "intake.md",
          kind: :agent,
          status_mode: :state_file_marker,
          budget_usd: 1.0,
          timeout_sec: 60
        ),
        Hive::Workflow::Stage.new(
          name: "gather",
          index: 2,
          state_file: "gather.md",
          advance_verb: Hive::Workflow::AdvanceVerb.new(name: "gather"),
          kind: :agent,
          status_mode: :state_file_marker,
          budget_usd: 1.0,
          timeout_sec: 60
        ),
        Hive::Workflow::Stage.new(
          name: "report",
          index: 3,
          state_file: "report.md",
          advance_verb: Hive::Workflow::AdvanceVerb.new(name: "report"),
          kind: :agent,
          status_mode: :state_file_marker,
          budget_usd: 1.0,
          timeout_sec: 60
        )
      ]
    )
  end

  def content_workflow
    Hive::Workflow.new(
      id: :content_fixture,
      stages: [
        Hive::Workflow::Stage.new(name: "inbox", index: 1, state_file: "idea.md", kind: :inert),
        Hive::Workflow::Stage.new(
          name: "research",
          index: 2,
          state_file: "research.md",
          advance_verb: Hive::Workflow::AdvanceVerb.new(name: "research"),
          kind: :agent,
          status_mode: :state_file_marker,
          budget_usd: 1.0,
          timeout_sec: 60
        ),
        Hive::Workflow::Stage.new(
          name: "draft",
          index: 3,
          state_file: "draft.md",
          advance_verb: Hive::Workflow::AdvanceVerb.new(name: "draft"),
          kind: :agent,
          status_mode: :state_file_marker,
          budget_usd: 1.0,
          timeout_sec: 60
        ),
        Hive::Workflow::Stage.new(
          name: "done",
          index: 4,
          state_file: "done.md",
          advance_verb: Hive::Workflow::AdvanceVerb.new(name: "done"),
          kind: :agent,
          status_mode: :state_file_marker,
          budget_usd: 1.0,
          timeout_sec: 60
        )
      ]
    )
  end

  def with_deterministic_content_agent(record: nil)
    original = Hive::Stages::Base.method(:spawn_agent)
    Hive::Stages::Base.define_singleton_method(:spawn_agent) do |task, **_kwargs|
      record << task.stage_name if record
      File.write(task.state_file, "# #{task.stage_name}\nartifact: #{task.stage_name}\n<!-- COMPLETE -->\n")
      { status: :complete }
    end
    yield
  ensure
    Hive::Stages::Base.define_singleton_method(:spawn_agent, original) if original
  end

  def with_registered_workflow(descriptor)
    original_fetch = Hive::Workflows::Registry.method(:fetch)
    original_all = Hive::Workflows::Registry.method(:all)
    original_ids = Hive::Workflows::Registry.method(:ids)
    Hive::Workflows::Registry.define_singleton_method(:fetch) do |id|
      id == descriptor.id ? descriptor : original_fetch.call(id)
    end
    Hive::Workflows::Registry.define_singleton_method(:all) do
      (original_all.call + [ descriptor ]).uniq(&:id)
    end
    Hive::Workflows::Registry.define_singleton_method(:ids) do
      (original_ids.call + [ descriptor.id ]).uniq
    end
    # Hive::Workflows.all_stage_dirs/all_stage_names memoize the registry union
    # (the registry is frozen in production, so the cache is permanent there).
    # This helper is the ONE place the registry mutates, so it must drop the
    # cache on both enter and exit or the fixture's stage dirs would be missing
    # inside the block and leak after it.
    reset_workflow_union_cache!
    yield
  ensure
    Hive::Workflows::Registry.define_singleton_method(:fetch, original_fetch) if original_fetch
    Hive::Workflows::Registry.define_singleton_method(:all, original_all) if original_all
    Hive::Workflows::Registry.define_singleton_method(:ids, original_ids) if original_ids
    reset_workflow_union_cache!
  end

  def reset_workflow_union_cache!
    Hive::Workflows.instance_variable_set(:@all_stage_dirs, nil)
    Hive::Workflows.instance_variable_set(:@all_stage_names, nil)
    Hive::Workflows.instance_variable_set(:@all_terminal_stage_dirs, nil)
  end
end
