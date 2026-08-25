---
title: Recover Patrol stages without inherited debounce state
type: fix
date: 2026-08-25
---

Daemon completion handling now removes a task's persisted dispatch baseline
when the task's current state file is in a different workflow stage from the
completed child or durable attempt. Review routes back to Patrol Fix, and
routes forward to publish, therefore enter the successor stage as first sight
instead of being misclassified as unchanged markerless runs. A successor file
edited after the child or durable attempt completed keeps the previous
baseline, so the newer edit remains eligible instead of being consumed by
completion reconciliation.

Genuine unchanged markerless runs are now rechecked under the task lock and
written as `ERROR reason=agent_exited_without_terminal_marker`. The existing
healer and sole RecoveryCoordinator resume them through the normal guarded
retry lifecycle. The marker transition is also a compare-and-set under the
marker sidecar lock, so live locks, concurrent markers, newer successor edits,
and moved folders win without being overwritten, consumed, or recreated.
