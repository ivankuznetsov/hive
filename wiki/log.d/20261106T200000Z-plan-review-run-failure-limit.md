# 2026-11-06 — plan-review-run stops redispatching identical failures

**Action:** Fixed the daemon redispatching a deterministically failing
`hive plan-review-run` with no backoff (inbox task
`the-daemon-redispatches-a-deterministically-261103-9bdd`). On hivedev C5,
2026-11-03 12:45–20:08 UTC, 393 durable attempts with one unchanged
`task_generation` each exited 4 ("plan review could not initialize from the
current plan", the PlanSignals byteslice bug fixed by #1596) about once a
minute; the row stayed `plan_reviewing` (scheduler-owned) throughout.

**Findings:** `Attempts::Dispatcher#admit` only paced failed terminals of the
same generation for stage transitions (`task stage != intended_stage`).
`plan-review-run` is same-stage, and its `plan_review` trigger does not set
`replay_semantic_terminal`, so every tick's fresh request id admitted a new
worker. Durable attempts never reach `ConcurrencyController#record_completion`,
so the exit-4 controller cooldown did not apply either.

**Change:** `CommandProgress::FAILURE_LADDER_COMMANDS` (`plan-review-run`)
joins the transition `RetryPolicy` ladder; after three consecutive `failed`
attempts with the same non-TEMPFAIL exit status on one generation, admission
defers with `repeated_failure_limit`. The daemon maps it to
`attempt_failure_limit` (new log event) with an operator-owned `needs_repair`
disposition naming the command, exit status, and latest attempt. The
plan-review-run progress token now includes the runtime digest, so editing the
plan, a plan-review projection change, a marker change, or a new Hive build
resets the series; an interactive operator run bypasses it.
