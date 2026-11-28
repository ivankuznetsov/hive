# 2026-11-27 — Invalid plan dependencies: early validation, bounded correction, and root-owned repair

- Preserves the 2026-10-30 operator decision keeping shipped scalar-or-list
  `depends_on` grammar, singleton/multi-item list policy (`9-done` gate,
  project-default base), exact duplicate deduplication, and additive
  strict-superset adoption (hive#1573), superseding the withdrawn scalar-only
  brainstorm premise.
- Shared read-only validation (`Hive::Dependencies`, `Hive::PlanFrontmatter`,
  `Hive::PlanDependencyAdoption`) validates bounded frontmatter, preserves all
  offending per-element zero-based indices/raw values (e.g., `[F2, F3]`),
  checks target resolution before any mutation or adoption, and provides
  evidence-only hints from a separate project-scoped active-plus-archived
  lookup (`DependencySnapshot.project_hint_lookup`) unioning slug prefixes and
  exact `<project>:<code>:<version>` `idempotency_key` matches only when
  coverage is complete and resolves to one distinct task.
- Planner prompts (`plan_prompt.md.erb`, `plan_revision_prompt.md.erb`)
  require full task slugs and forbid task-code shorthand. Initial plan runs
  (`Stages::Plan`) and plan-review revisions (`PlanReview::Orchestrator`) grant
  at most one automatic correction backed by controller-owned durable custody
  (`plan-dependency-correction.json`, protected by `ArtifactFirewall`); second
  invalid outputs stop under operator ownership (`ERROR` /
  `plan_dependency_correction_exhausted`) with `Policy.decide` returning
  `:skip`.
- Every execution-allowing plan-review terminal state (`skipped`, `cleared`,
  `degraded_cleared`) publishes through one guarded custody path in
  `Orchestrator#terminal` after validating against an outside-lock immutable
  context and rechecking digests/observations under lock. Previously cleared
  invalid plans return a controller diagnostic with zero spawns and immutable
  historical clearance records; `TransitionGuard.verify!`, daemon
  `PlanApproval`, `Approve`, and execute entry revalidate current `plan.md` and
  `meta.yml` despite `depends_on` exclusion from `task_generation`.
- Explicit operator `hive plan <root-slug> --project <project> --from 3-plan`
  carries local plan-repair intent (withheld from automated daemon dispatches)
  to start one fresh bounded invocation even while invalid bytes remain in
  `plan.md`.
- Admission (`Hive::DependencyAdmission`) attributes covered plan defects
  (`plan_dependency_invalid`, `plan_dependency_mismatch`, unadopted
  `plan_dependency_missing`) to their owning root(s) via typed
  `dependency_repair_roots`: descendants with only inherited covered defects
  evaluate as `:wait` (`admission_error: null`, raising `DependencyWaitError`
  exit 75 through `enforce_admission!` rather than `DependencyAdmissionError`
  exit 78), independently broken descendants retain local `:error` alongside
  inherited roots, and noncovered errors (cycles, metadata-only missing
  targets, cross-project/environment faults, cancelled/superseded targets,
  ambiguity) keep existing behavior unchanged.
- Optional additive `dependency_repair_roots` declared in `hive-status.v9`,
  `hive-operational-status.v5`, `hive-stack.v1`, and `hive-task-workspace.v2`
  without widening closed `AdmissionError`, `UnmetDependency`, or `REASON_CODES`
  enums, and rendered consistently across CLI (`status`, `task`, `stack`),
  daemon (`StatusConsumer`, `OperationalSnapshot`, `Dispatcher`, `Policy`),
  TUI (`Snapshot`, `TasksPane`, `RedStatusDetail`), and Web (`StatusPayload`,
  `TaskDisplay`, `tasks/show`, `tasks/_dependencies`).
- Updated wiki pages: `wiki/stages/plan.md`, `wiki/modules/task_dependencies.md`,
  `wiki/modules/plan_review.md`, `wiki/commands/status.md`,
  `wiki/commands/run.md`, `wiki/commands/stage_action.md`, and
  `wiki/modules/daemon.md`.
- Acceptance integration tests: `test/support/plan_dependency_incident_fixture.rb`,
  `test/integration/run_plan_test.rb`,
  `test/integration/plan_review_lifecycle_test.rb`,
  `test/integration/dependency_admission_test.rb`.
