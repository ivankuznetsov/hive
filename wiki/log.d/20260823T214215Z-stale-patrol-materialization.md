## [2026-08-23T21:42:15Z] Patrol Fix — re-admit stale materialization decisions

**Action:** Changed Patrol Fix admission scheduling to preserve the
materializer's stale-candidate reset. When final candidate revalidation moves a
decided admission back to `pending`, the scheduler now emits a stale event and
allows a fresh semantic decision instead of incorrectly writing a
`materialization_failure` retry onto the reset record. Genuine materialization
failures retain their bounded retry behavior.

**Verification:** Added a regression covering the exact decided-to-pending
transition and proving that no retry metadata is written before the next
semantic decision dispatch.

**Refreshed pages:**
- [[modules/patrol]]
