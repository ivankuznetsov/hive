require "hive/stages"
require "hive/task_meta"
require "hive/dependencies"

module Hive
  # Disk→resolver glue for task dependencies. `tasks` reads every stage
  # folder's meta.yml into the shape `Hive::Dependencies` consumes;
  # `current_task`/`depends_on` project the task-under-evaluation into the
  # same shape. Every production caller passes a `Hive::Task`, which exposes
  # #slug, #id, #depends_on, #folder, and #project_root directly — the
  # snapshot does not duck-type other inputs.
  module DependencySnapshot
    module_function

    def tasks(project_root)
      Hive::Stages::DIRS.each_with_index.flat_map do |stage, index|
        stage_dir = File.join(project_root, ".hive-state", "stages", stage)
        next [] unless File.directory?(stage_dir)

        Dir.children(stage_dir).sort.filter_map do |entry|
          folder = File.join(stage_dir, entry)
          next unless File.directory?(folder)

          meta = Hive::TaskMeta.read(folder)
          {
            slug: meta[:slug] || entry,
            id: meta[:id],
            stage: stage,
            stage_index: index + 1
          }
        end
      end
    end

    def current_task(task)
      { slug: task.slug, id: task.id }
    end

    def depends_on(task)
      task.depends_on
    end

    # Resolve the branch a dependent task's worktree / PR should stack
    # onto. Shared by 4-execute (worktree base) and 5-open-pr (PR base) so
    # the read-depends_on → load-snapshot → resolve → null-out-when-default
    # scaffolding lives in one place. Returns nil when the task has no
    # dependency, or when a set dependency does not resolve to a stacked
    # base (typo / prereq transiently absent from the snapshot /
    # self-reference) — and warns in that latter case so a silently
    # collapsed stack is observable at execute/open-pr time rather than
    # only via the fail-closed daemon gate. Lives here (the disk-reading
    # layer) rather than in the pure `Hive::Dependencies` resolver so the
    # resolver stays free of disk I/O.
    def stacked_base(task, default_branch)
      dependency = depends_on(task)
      return nil if dependency.to_s.strip.empty?

      base = Hive::Dependencies.base_branch_for(
        depends_on: dependency,
        tasks: tasks(task.project_root),
        default_branch: default_branch,
        task: current_task(task)
      )
      if base == default_branch
        warn "[hive] dependency: #{task.slug} depends_on #{dependency.inspect} " \
             "but it did not resolve to a stacked base (prerequisite missing " \
             "from the snapshot or self-reference); branching from #{default_branch}"
        return nil
      end

      base
    end
  end
end
