# 2026-11-06 — plan review: restart a stale review; keep and bound rejected reviewer output

**Action:** Fixed two plan-review dead ends from hivedev (inbox tasks
`a-plan-review-made-stale-261103-5606` and
`plan-review-verification-output-rejected-261103-b6d3`).

**Findings:**
- C11 (`c11-build-the-egress-proxy-260923-b053`): the review recorded its
  generation under the legacy raw-`meta.yml` formula, so an operator
  `depends_on` edit staled it permanently. `DecisionService#apply` rejected every
  action on a stale review ("plan review changed; refresh the current
  observation") and `show` returned only the stale generation, so nothing an
  operator copied from `show` could succeed. The daemon would supersede it via
  `plan-review-run`, but C11 is dependency-blocked on F4, so its overdue
  `retry_at` (2026-10-30) sat as a plain scheduler wait.
- F4 (`f4-run-the-hosting-proof-260923-7bae`): `CeDocReview#call` turned
  `ResultParser` rejections into `retryable_failure` and discarded the bytes;
  the diagnostic was a bare "invalid plan review coverage entry". Mandatory
  primary/adversarial legs recover transient series automatically, so a
  deterministic rejection paid for attempts indefinitely. The #1613 attempt
  limit cannot see these: each attempt changes the plan-review progress token.

**Change:**
- New `restart` plan-review action, valid only on a stale review; it records
  the decision and the resumed orchestrator starts a linked review for the
  current generation (always, even for configuration-only drift). Stale
  rejections now name it. `show` adds `current_task_generation`,
  `next_action`, and `blockers`.
- Operational status reports a `retry_scheduled` review more than an hour past
  `retry_at`, with no dependency holding it, as `needs_repair`/`hive`
  (`plan_review_retry_overdue`).
- Parser rejections keep the raw output as
  `attempts/<attempt>/rejected-output.md` (redacted, 64 KiB bound, parse
  error); coverage diagnostics name the offending key or value; echoed
  `fingerprint`/`decision_id` coverage keys are dropped. Three identical
  consecutive rejections of one role block the review with an operator-owned
  `reviewer_output_rejected` blocker naming the error and file.
