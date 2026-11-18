---
title: Plan review batches operator decisions into one revision round
type: fix
created: 2026-11-18
updated: 2026-11-18
tags: [plan-review, revision-round, operator-decision, task-action, incident]
---

On todero task `agent-and-app-api-v1-261105-7d3c` (2026-11-16), two gated
findings were open at once. Approving the first started a planner revision with
only that finding, and the revision used the last round (the
`OPERATOR_DECISION_ROUNDS` integration round). Approving the second then hit
`revision_round_limit`. The review went `blocked` and asked for a new linked
plan, even though the operator had answered everything.

- `Orchestrator#resume_review` no longer launches a planner revision while any
  `gated_auto` or `manual` finding is open, even when other findings are
  already accepted. It parks in `awaiting_decision` with the next open finding
  as `required_action`. When the last decision lands, one revision integrates
  every accepted finding: operator approvals and answers, auto-accepted
  `safe_auto` fixes, and policy-approved gates.
- `prepare_verification_followup` follows the same rule. A verifier that
  reopens a safe residual and raises a new gate parks the review instead of
  revising the residual alone.
- Both call sites share one fence, `revision_round_limit_block`. Open choices
  count toward the operator-decision round in `revision_round_limit_reached?`,
  so a review at its base budget waits for them instead of blocking on safe
  residue. Past the extra round it blocks, open choice or not, and stays
  blocked on re-entry.
- Incorporated candidates that an older build revised mid-decision are still
  verified before the review parks, because verification spends no round.
- `TaskAction#auto_plan_review_decision?` now treats accepted findings beside
  an open choice as the operator's wait (`plan_review_decision`). The old rule
  made them `plan_reviewing`, so the daemon would have re-dispatched
  `plan-review-run` only to republish the same wait.
- A `revision_round_limit` block's `required_action` (and so the operational
  reason) is now `start a new linked plan: hive run <slug> --project <project>
  (operator decisions carry forward)`. It replaces "resolve remaining findings
  with a new linked plan". No routine replan action was added: `workflow.advance`
  is daemon-admissible, and an automatic replan would restart the linked-plan
  loop. `TaskAction#unsupported_review?` ignores this block, because the slug
  inside the action could otherwise match its capability/configuration/reviewer
  regex.
- **Trade-off:** safe fixes now wait behind an open choice. The operator decides
  against a plan without them, and their verification findings appear only
  after the last decision.
- **Tests:** two simultaneous gates (no revision after the first approval, one
  revision with both after the second); manual plus gated plus a deferred safe
  fix, decided out of order; the live repro at a one-round base budget; a
  verification follow-up gate holding a reopened residual; the ceiling fence
  at the follow-up with the replan command; TaskAction ownership and the
  slug-regex guard; the operational reason text. Five existing legacy-path
  tests now build their mid-decision records with an `unbatched` runner.
