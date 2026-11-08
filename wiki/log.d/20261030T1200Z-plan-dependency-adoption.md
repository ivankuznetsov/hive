# 2026-10-30 — Plan dependency adoption follows revisions and supersets

- `meta.yml` gates dispatch, but the plan stage only copied a plan's
  frontmatter `depends_on` into it after the initial planner run and only when
  metadata had none. Observed three times on hivedev on 2026-10-30, each
  needing an operator to hand-edit `meta.yml`:
  - f2-follow-up: the dependency
    (`hivedev:f2-build-the-pinned-workspace-260923-d691`) first appeared in a
    plan-review planner revision promoted at clearance, so admission reported
    `plan_dependency_missing` (`needs_repair`). The hand edit then changed the
    plan-review task generation and restarted the whole critique.
  - c11: metadata had `f2-…` from task creation; the plan declared
    `[f2-…, f4-…]`, so admission reported `plan_dependency_mismatch`.
  - c5: metadata had one dependency; a revision declared a superset.
- New `Hive::PlanDependencyAdoption.adopt!` holds the rule: adopt when
  metadata has no `depends_on` or the plan's declaration is a strict superset
  (compared by target with the new `Dependencies.reference_identity`, which
  shares `reference_project` with admission's `resolve_project`, so
  `hivedev:slug` equals bare `slug` in hivedev). It never drops, replaces,
  re-spells, or reorders an existing metadata edge, so those still produce
  `plan_dependency_mismatch`. Self-reference and observation/staleness guards
  are unchanged.
- It runs after the initial planner (`Stages::Plan.adopt_plan_dependency!`)
  and inside `PlanReview::Orchestrator` right after `promote_candidate!`.
- `PlanReview::Identity.task_generation` now excludes `meta.yml`'s
  `depends_on`, so adoption at promotion does not stale the review it
  completes. `task_generation_current?` also accepts the legacy raw-bytes
  generation for reviews recorded before this change.
- Tests: `test/unit/stages/plan_test.rb`,
  `test/unit/plan_review/orchestrator_test.rb`,
  `test/unit/plan_review/identity_test.rb`,
  `test/unit/dependency_admission_test.rb`.
