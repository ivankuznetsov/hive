require "hive/task_meta"

module Hive
  module Reviewers
    # Minimal task-shaped facade used by every shared review sub-spawn
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
      :folder, :state_file, :log_dir, :stage_name, :project_root, :slug, :id, :workflow,
      keyword_init: true
    )

    module_function

    # Preserve the owning workflow identity for journal-backed sub-spawns.
    def synthetic_task_for(ctx, project_root: nil)
      metadata = Hive::TaskMeta.read(ctx.task_folder)
      SyntheticTask.new(
        folder: ctx.task_folder,
        state_file: File.join(ctx.task_folder, "task.md"),
        log_dir: File.join(ctx.task_folder, "logs"),
        stage_name: File.basename(File.dirname(ctx.task_folder)),
        project_root: project_root,
        slug: metadata[:slug] || File.basename(ctx.task_folder),
        id: metadata[:id],
        workflow: metadata[:workflow] || "coding"
      )
    end
  end
end
