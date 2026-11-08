---
date: 2026-09-26
slug: external-scheduler-review-pass-01
---

## External scheduler review fixes

**Action:** Closed the first accepted review pass for scheduler-driven one-shot
execution. Readiness now preserves scheduler failures, project-local caps remain
runnable, Patrol Fix and module continuations stay visible, and scoped recovery,
draining, signal settlement, malformed inventory reporting, and canonical project
ownership fail safely. Shared adapter, wake-grouping, usage-contract, and child
process lifecycle helpers remove the duplicated paths identified by review.

Persisted dispatch quarantine and dropped-project holds now have the stopped-daemon
`hive daemon clear-hold PROJECT [SLUG]` recovery control. The command, one-shot
schemas, component inventory, and focused regression suites document and verify the
updated behavior.
