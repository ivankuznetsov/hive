## 2026-08-15 — Plan-review surface line coverage (CLI, meta, action, TUI, migrate)

The coverage gate reported 99.88% with 110 uncovered lines. This pass closed
the eleven that sit on non-plan-review files the feature touched, where the
uncovered line was a *branch the feature added* rather than plan-review logic
proper:

- `cli.rb` — the `plan-review-run` verb body (require + `PlanReviewRun.new`)
  had no dispatch test; `plan-review` had one but its sibling did not.
- `commands/migrate.rb` — the `plan_review_requirement_count` clause of
  `migration_complete_message`, including the singular/plural label split.
- `task_meta.rb` — `normalize_plan_review_required` has two exits that no test
  reached: the `strict: true` raise (only `write` passes it) and the
  non-strict `warn` + `nil` downgrade (only `read` passes it). A `false` value
  is the discriminator for both.
- `task_action.rb` — the default `clock:` lambda (every existing test injected
  a clock, so `Time.now.utc` was cold), the `retry_due?` rescue for an
  unparseable `retry_at`, and the `routes[].capability_result == "unsupported"`
  fallback, which is only reached when `required_action` does *not* already
  match `/capability|configuration|reviewer/i`.
- `tui/bubble_model.rb` — `finalize_plan_marker`'s guard that the command
  returned by `PlanApproval.prepare` is the same develop command that was
  validated. A prepare that substitutes a different command must abort with
  the marker still `:waiting`; the raise is caught by the `ArgumentError`
  rescue in the advance path.

`route_resolver.rb` followed in the same pass: the `verification` and
`else` arms of `default_candidates`, the `fallbacks` row mapping in
`configured_candidates`, and three validation raises.

One finding worth carrying forward: `normalize_candidate`'s
`require_family: true` branch (`"plan review route family must be attested"`)
has **no production caller** — `resolve` is the only caller and always passes
`require_family: false`, downgrading an unknown family to `nil` instead of
rejecting it. The parameter is vestigial; the branch is covered by calling the
method directly. Either drop the parameter or route a caller through it.
Likewise `normalize_observed_identity`'s per-key raise is only reachable for a
*non-String* value — blank strings are filtered out by the preceding `reject`.

Remaining uncovered after this pass (93 lines): `commands/plan_review.rb`,
`config.rb` plan-review validation, `plan_review/decision_service.rb`,
`orchestrator.rb`, `planner_revision.rb`, `transition_guard.rb`.

See [[modules/plan_review]], [[modules/task_action]] and [[testing]].
