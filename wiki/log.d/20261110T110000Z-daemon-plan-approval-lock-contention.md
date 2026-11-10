---
date: 2026-11-10
type: fix
---

The daemon no longer dies when plan approval hits task-lock contention. `Hive::Daemon::PlanApproval.prepare` takes the task lock. When a stale `plan_waiting` row was approved while the task's next-stage run already held the task lease, `Hive::ConcurrentRunError` ("another hive run is active for …/3-plan/…") escaped the tick and ended the daemon process.

Seen in the golden-path E2E on PR #1644: the daemon's events stopped mid-tick, the task never left EXECUTE, and the test timed out. In production, systemd restarts the daemon, so the cost there was a dispatch outage.

The dispatcher now logs `:skipped reason: plan_approval_busy` and retries on the next tick. Operational status classifies the `plan_approval_busy` decision as a scheduler wait.
