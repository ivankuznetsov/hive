## [2026-08-14T23:30:00Z] plan review — pin the operator-facing surface branches

**Action:** No behavior change. Continues the coverage grind started in
[[log]] `20260814T220000Z-plan-review-validation-coverage`, which left 220
uncovered lines under the 100% line gate. This pass closes 27 of them on the
operator-facing surfaces — error classification and status rendering — rather
than the subsystem internals.

**Coverage:**

- `Commands::PlanReview#envelope_error_kind` — a new
  `test/unit/commands/plan_review_test.rb` maps every typed failure
  (`StaleDecision`, `ConflictingDecision`, `UnauthorizedAction`,
  `InvalidAction`, `AmbiguousSlug`, `InvalidTaskPath`, `ConcurrentRunError`,
  `ConfigError`, `GitError`, `InternalError`) plus the untyped fallback, and
  pins `normalized_operator`'s caller → `$USER` → `local-operator` precedence.
- `Commands::Approve.error_kind_for` — pins `plan_review_blocked`. Because
  `PlanReview::TransitionBlocked` subclasses `Hive::WrongStage`, the branch
  order is load-bearing, so the case now asserts both kinds.
- `Commands::Status#operational_plan_review_token` — pins the rendered
  `level/state coverage=n/m open=k` token, the `effective_level` →
  `computed_level` → `"pending"` fallback chain, and the empty-hash and
  non-Hash inputs.
- `OperationalStatus#classify` / `#operational_review_owner` — pins that
  plan-review wait actions defer to `scheduler` only when the daemon is
  enabled and otherwise report the review blocker owner, that repair actions
  report that owner directly, and that reviewer-side roles (`reviewer`,
  `planner`) collapse to `agent` while unrecognized owners fail closed to
  `unknown`.

**Remaining:** roughly 193 uncovered lines remain, concentrated in
`orchestrator`, `ce_doc_review`, `config`, `store`, `transition_guard`,
`plan_signals`, `decision_service`, `planner_revision`, `route_resolver`, and
`commands/plan_review`'s resolve/persist paths. The coverage gate is still red.
See [[testing]] and [[modules/plan_review]].
