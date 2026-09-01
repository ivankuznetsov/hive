---
title: Cut task and Patrol coordination over to SQLite
date: 2026-08-29
tags: [sqlite, sequel, task-lease, patrol, counter, fork]
---

- Replaced ordinary task lock/guard files with stable-id `task_leases` rows,
  compare-and-swap fencing, process-start identity reclaim, bounded payloads,
  thread/process reentrancy, moved-task observation, and fail-closed project,
  recreated-path, and custom-state-root identity checks.
- Replaced the task counter and Patrol discovery allowance/provider-hold
  ledgers with immediate Sequel transactions. UsageDb remains telemetry and
  one-time seed evidence outside the transaction; reservation and seed state
  are bounded.
- Made compact running status one bounded active-lease join instead of a task
  directory scan plus per-task lease lookups. The v1 counter names remain
  stable while their descriptions identify SQLite source rows.
- Added one process-wide checkout/fork barrier for every registered Database
  wrapper, including temporary diagnostics connections. Fork, double-fork,
  daemon, self-exec, Puma worker, and spawned-agent boundaries leave no open
  SQLite descriptor in children.
- Fenced Drop and marker clearing with commit-lock then task-lease ordering;
  removed retired task-lock ignores, metadata/closure file guards, counter
  path helpers, and filesystem compatibility fixtures. `.commit-lock` remains
  the repository Git-index mutex.
- Bound each dispatcher task-source observation before admission and retained
  the final in-transaction fingerprint/epoch recheck, so a lease bootstrap
  placeholder cannot reject an unchanged task or weaken concurrent-change
  fencing.
