---
title: Plan-review-refused execute entry is an operator-owned stop
type: fix
created: 2026-11-11
updated: 2026-11-11
tags: [execute, plan-review, recovery, daemon, operational-status, approve]
---

Execute entry refused by `PlanReview::TransitionGuard` (hivedev, 2026-11-10:
`plan.md` edited in `6-review`, task moved back with
`hive approve --to 4-execute --from 6-review`) used to exit 4 with no marker.
The healer turned that into `ERROR reason=agent_exited_without_terminal_marker`,
status said "automatic retry is eligible", `hive task --json` said the task had
no operator action, and every retry repeated the refusal (ADR-058).

- `Execute.run!` now writes `ERROR reason=plan_review_blocked` (attrs
  `blocker`, the guard's `required_action`, `review_id`, `review_state`, and a
  remedy `message`) before re-raising the refusal, whose message ends with a
  `next:` remedy: `hive approve TASK --to 3-plan --from 4-execute`, then
  `hive plan-review TASK restart` or `hive plan-review-run TASK`, or restore
  the reviewed `plan.md`. A validated outcome-evidence rework is unchanged.
- `Hive::Recovery::OPERATOR_OWNED_ERROR_REASONS` (`model_unsupported`,
  `plan_review_blocked`) replaces the ModelUnsupported-only checks in
  `RecoveryCoordinator`, the dispatcher, operational status, and the daily
  digest hold observer. The healer never admits either; human retries still
  do. Assessments carry `operator_reason`.
- Operational status names the remedy as the row reason and in a
  `blocked`/`operator` recovery block; TaskAction labels the row
  `Plan review blocks execution` with a marker-sourced diagnostic; `hive task
  --json` uses the remediation as the disabled action's reason.
- Backward `hive approve` into `4-execute` from a later coding stage runs the
  read-only `TransitionGuard.validate_execute_reentry!` preflight and refuses a
  blocked review with the remedy (`--force` does not bypass; policy drift alone
  passes). `TransitionBlocked` gained `blocked_reason`.
- Pages: [[stages/execute]], [[modules/plan_review]], [[modules/daemon]],
  [[commands/daemon]], [[commands/status]], [[commands/approve]],
  [[commands/task]], [[decisions]] (ADR-058), [[gaps]].
