require "hive/dependencies"
require "hive/plan_frontmatter"
require "hive/task_meta"

module Hive
  # A plan that declares `depends_on` in its frontmatter is stating a real
  # scheduling constraint, but only meta.yml gates dispatch. Leaving the two
  # out of step parked the task on an admission error whose only remedy was
  # an operator copying one string between two files — toil that reviews
  # nothing, since nobody re-derives whether the dependency is right before
  # pasting it.
  #
  # The rule: adoption may add dependencies, never drop or replace one.
  #
  # - meta.yml has no `depends_on`: persist the plan's declaration.
  # - the plan's declaration is a strict superset of meta.yml's: persist the
  #   plan's declaration. Every existing edge is kept and scheduling only gets
  #   stricter. References are compared by what they point at, using the same
  #   project rule admission resolves with (`Dependencies.reference_identity`),
  #   so `app:slug` and a bare `slug` in project `app` are one edge. When a
  #   scalar meta edge grows into a plan list, the task also moves to list
  #   policy (every prerequisite at `9-done`, branch from the project default),
  #   which is consistent because nothing is stacked on an unmerged branch.
  # - anything else (the plan omits, renames, or changes an existing meta
  #   dependency, or merely re-spells or reorders the same set): leave
  #   meta.yml alone, so `plan_dependency_mismatch` still stops for a human.
  #
  # An adopted dependency is not trusted blindly: admission still resolves the
  # target and still reports `dependency_cycle` with the offending path, which
  # is a far better error than a copy instruction. A declaration naming the
  # task itself is never adopted.
  #
  # This runs wherever plan.md is written: after the initial planner spawn
  # (`Stages::Plan`) and when plan review promotes a revised candidate
  # (`PlanReview::Orchestrator`). The plan-review task generation excludes
  # `depends_on`, so adopting at promotion does not stale the review it
  # completes.
  module PlanDependencyAdoption
    module_function

    def adopt!(task, observation:)
      Hive::TaskMeta.validate_observation!(task.folder, observation)

      plan = Hive::PlanFrontmatter.read(File.join(task.folder, "plan.md"))
      return unless plan.valid?

      declared = plan.depends_on
      return if declared.nil?
      return if self_reference?(task, declared)
      return unless adoptable?(declared, Hive::TaskMeta.read(task.folder)[:depends_on], task)

      result = Hive::TaskMeta.rewrite(
        task.folder,
        { depends_on: Hive::Dependencies.serialize_declaration(declared) },
        observation: observation
      )
      warn "[hive] plan: stale task; dependency adoption skipped for #{task.slug}" if result.stale?
      nil
    rescue Hive::TaskMeta::StaleTask, Errno::ENOENT, Errno::ENOTDIR
      warn "[hive] plan: stale task; dependency adoption skipped for #{task.slug}"
      nil
    rescue Hive::TaskMeta::InvalidMetadata, SystemCallError, IOError, ArgumentError => error
      warn "[hive] plan: dependency adoption failed for #{task.slug} " \
           "(#{error.class}: #{error.message.to_s.byteslice(0, 240)})"
      nil
    end

    # PlanFrontmatter already parsed and validated `declared` into a Reference
    # or an array of References; malformed declarations never reach here.
    def self_reference?(task, declared)
      Array(declared).any? do |reference|
        same_slug = reference.task == task.slug
        same_numeric_id = !reference.explicit_project && reference.task == task.id.to_s
        same_qualified_identity = reference.explicit_project &&
          reference.project == task.project_name && same_slug
        (!reference.explicit_project && same_slug) || same_numeric_id || same_qualified_identity
      end
    end

    # `current` is meta.yml's raw value; an unparseable one raises
    # InvalidReference (an ArgumentError) and is reported, never replaced.
    def adoptable?(declared, current, task)
      return true if current.nil?

      planned = Array(declared).map { |reference| identity(reference, task) }.uniq
      existing = Hive::Dependencies.declaration_references(current)
                                   .map { |reference| identity(reference, task) }.uniq
      (existing - planned).empty? && !(planned - existing).empty?
    end

    def identity(reference, task)
      Hive::Dependencies.reference_identity(reference, task.project_name)
    end
  end
end
