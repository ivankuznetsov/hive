---
title: Patrol Fix retries agent-owned failures on the attempt failure ladder
type: change
created: 2026-11-15
updated: 2026-11-15
tags: [patrol, patrol-fix, daemon, attempts, recovery, operational-status]
---

Dogfood b6d6001077 (2026-11-14): the todero Patrol Fix
`sidebar-more-lists-…-8c075437bb0d` failed four times at `2-fix` with
`fix_report_invalid` (the report contract fixed in #1658). Status showed
`needs_repair`, owner `hive`, `retry: null`. The healer's markerless recovery
did retry twice, paced by the one-hour `patrol_retry_delay`. After a restart,
the queued recovery request attached to the first-sight attempt and stayed
`dispatched` overnight, so nothing ran again until the task changed.

- **Owner.** `AttemptDiagnostic` now labels `fix_report_invalid`, and
  `fix_worktree_dirty` raised at the Fix stage (the agent reported `fixed` but
  left its own worktree uncommitted), as `agent`. The dirty code at Validate,
  Review, and Publish, custody mismatch, validation mutation, protected Git
  config tamper, the state Git lock, and the secret publication block stay
  `hive`.
- **Retry.** For a `ready_to_run` row on first sight or on the markerless
  brake, the daemon reads the typed diagnostic bound to `current_attempt`. An
  agent-owned failure dispatches with trigger `agent_failure_retry`.
  Admission skips the flat Patrol delay and uses the plan-review ladder:
  `RetryPolicy` backoff on the attempt's retry charge, then
  `repeated_failure_limit` after three identical failed exits on the same
  generation and Hive build, counted from attempt rows
  (`recent_terminal_attempt_ids(runtime_digest:)`). The daemon records
  `retry_cooldown` with `retry_at` (scheduler-owned) while backoff is pending,
  and operator-owned `attempt_failure_limit` naming the count, exit, latest
  attempt, code, and `hive run SLUG --project NAME` at the limit.
- **No retry for integrity.** A Hive-owned failure is held as operator-owned
  `attempt_integrity_hold` with the code and the same command. It never
  reaches admission or markerless recovery.
- Provider-owned failures and exit-0 runs without progress keep the existing
  markerless-stall brake.

Tests: `test/unit/attempts/dispatcher_test.rb` (ladder, limit, interactive
bypass, new-build reset), `test/unit/daemon/dispatcher_test.rb` (route,
backoff disposition, limit reason, integrity hold, markerless fallbacks,
capacity fence, readiness), `test/unit/operational_status_test.rb`,
`test/unit/attempts/patrol_dispatch_replay_test.rb`,
`test/unit/patrol_fix/runner_test.rb`, and
`test/unit/stages/managed_agent_custody_test.rb` (owners).
