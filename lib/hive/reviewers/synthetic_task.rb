require "hive/task_meta"

module Hive
  module Reviewers
    # Minimal task-shaped facade used by every 6-review sub-spawn
    # (reviewers, triage, ci-fix, browser-test). The orchestrator's real
    # Task is owned by the runner; sub-spawns receive a Reviewers::Context
    # with paths only and need a struct with paths plus durable task identity
    # to satisfy both `Hive::Stages::Base.spawn_agent` and journal-backed
    # implementation ownership.
    #
    # Pre-M-04 this was redefined verbatim in four places; one shared
    # struct keeps the contract uniform and lets a future stage_name
    # override flow through one place.
    SyntheticTask = Struct.new(
      :folder, :state_file, :log_dir, :stage_name, :project_root, :slug, :id,
      keyword_init: true
    )

    module_function

    # Build a SyntheticTask from a Reviewers::Context. Stage_name is
    # always "6-review" because every sub-spawn here is part of the # coding-scoped: synthetic reviewers run only inside coding review
    # review autonomous loop.
    def synthetic_task_for(ctx, project_root: nil)
      metadata = Hive::TaskMeta.read(ctx.task_folder)
      SyntheticTask.new(
        folder: ctx.task_folder,
        state_file: File.join(ctx.task_folder, "task.md"),
        log_dir: File.join(ctx.task_folder, "logs"),
        stage_name: "6-review", # coding-scoped: synthetic reviewers run only inside coding review
        project_root: project_root,
        slug: metadata[:slug] || File.basename(ctx.task_folder),
        id: metadata[:id]
      )
    end
  end
end
