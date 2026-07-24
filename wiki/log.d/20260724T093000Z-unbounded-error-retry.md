## [2026-07-24T09:30:00Z] daemon - make every error retryable

**Behavior:** `ERROR` and `REVIEW_ERROR` are now durable diagnostic states,
not permanent workflow terminals. Every reason uses the same shared
marker-age cooldown. Clears
remain generation-guarded and skip live controller/task-lock owners. Failed
reruns write a fresh marker and restart the cooldown, with no exhaustion
budget.

This includes formerly manual-only preflight, tamper/integrity,
dirty-worktree, unknown, and timeout reasons. Bot Autofix now offers the same
guarded clear-and-rerun path. Durable attempt-loss recovery also remains
pending across unverifiable process identity or missing-task observations, and
`retry_charge` is lineage evidence rather than a three-attempt terminal cap.
Successor admission is paced by a persisted shared cooldown rather than every
daemon tick.

**Why:** Hive cannot know whether files, configuration, credentials, provider
state, or the configured agent binary changed after an error was written. The
rerun is the universal health probe. Current operator input or dirty execute
work temporarily defers a clear, and the new attempt still re-applies every
ordinary stage validation.

**Tests:** Updated stale-agent, dependency-recovery, attempt-loss, bot
notification, and recovery-sequence coverage to pin repeated retries beyond
the former budgets, one cooldown for every reason, preserved
ownership/marker guards, and the absence of exhaustion events.
Coverage also pins the global/project enable gates, non-expiring `3-plan`
continuation across temporary project-config removal, enqueue-failure marker
restoration, lost-successor cooldown, and scheduler-owned operational status
while automatic retry is enabled.
