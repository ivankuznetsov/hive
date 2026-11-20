## 2026-11-20 — Daemon survives busy admission bookkeeping

- Incident: at 18:39:31 `hive-daemon.service` (deployment `cc0628924`)
  logged a 13.26 s `attempt.observe_task_source` writer hold while a large
  container build loaded the host. It then logged
  `runtime_bookkeeping_busy: admission exhausted after 0.0s (0 busy tries)`
  and exited 75. Dispatch stopped for every project until systemd restarted
  the daemon 30 s later.
- Daemon root cause: `Hive::Attempts::BookkeepingBusy` reached
  `run_forever`. The row loop rescued only `RuntimeDatabaseBusy` and
  `InvalidAttemptRecord`. `survive_runtime_database_busy` only recognised a
  SQLite busy in the cause chain, and a zero-try `BookkeepingBusy` has no
  cause.
- Daemon fix: `dispatch_prioritized_rows` defers on `BookkeepingBusy` the
  same way as on `RuntimeDatabaseBusy`. It logs `dispatch_deferred` with the
  typed reason, operation, attempt id, try count, elapsed and budget, then
  stops the pass, and the next tick re-admits the row. `run_forever` also
  survives a top-level `BookkeepingBusy` or `RuntimeDatabaseBusy`
  (`tick_deferred` plus a failed snapshot with the typed reason). Storage
  failures whose cause is a `BookkeepingBusy` still propagate.
- Budget root cause: `Dispatcher#admit` took one 30 s deadline before
  `observe_source`. That observation (and any unbudgeted reads after it) spent
  the deadline, so the admission write's `BookkeepingRetry` started already
  expired and exhausted before its first try. Elapsed was measured from that
  retry's own construction, which is why the log said 0.0 s.
- Budget fix: `observe_source` and `read_admission` each get their own
  budget. The durable chain (admission, arm_handoff, reservation, claim,
  first heartbeat) shares one budget that starts immediately before
  `create_launching`. The `starting_revision` git call now runs once outside
  the one-second admission try. `BookkeepingRetry` accepts `started_at:` (the
  shared budget origin), reports elapsed from it, and labels zero-try
  exhaustion `0 busy tries; budget spent before the first try`.
- Tests: the incident regression in `test/unit/attempts/dispatcher_test.rb`
  (a slow observation, then a busy admission try that is retried and
  accepted). Also there: an admission give-up that leaves no attempt or
  launch and reports truthful elapsed and try count, and pending-bookkeeping
  evidence after an `arm_handoff` give-up. `BookkeepingRetry` tests cover
  origin-based elapsed and the message text. Daemon tests cover a tick that
  defers and re-admits on the next tick, `run_forever` surviving a
  cause-less `BookkeepingBusy`, and a wrapped storage failure still
  propagating.
- Pages: [[modules/daemon]], [[modules/attempts]], [[gaps]].
