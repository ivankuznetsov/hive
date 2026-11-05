# 2026-11-05 — Runtime database lock contention no longer kills the daemon

**Action:** At 18:27 UTC `hive-daemon` exited with
`hive: attempt task source could not be observed: SQLite3::BusyException:
database is locked`, hit the same error on each restart, and stopped with
`start-limit-hit`; every project stalled for about 4.5 hours. The path was
`Daemon::Dispatcher#dispatch_prioritized_rows` → `handle_row` →
`Attempts::Dispatcher#admit` → `Repository#observe_task_source`, whose
`BEGIN IMMEDIATE` lost the 15 s busy timeout to another `hive` process. The
error became a plain `RepositoryError`, escaped the row loop and
`run_forever`, and `bin/hive` exited 1.

- `Attempts::Repository#translate_store_error` raises
  `Hive::Attempts::StoreBusy < RepositoryError` (exit 75) when the cause
  chain is a SQLite busy/lock-timeout error.
- The daemon row loop logs `dispatch_deferred` (`reason:
  runtime_database_busy`) and ends that dispatch pass; the next tick retries.
- `run_forever` survives any tick that raises a SQLite busy error (logs
  `tick_deferred`, publishes a failed operational snapshot).
- Startup dispatch-claim recovery retries busy with 2/5/10 s backoff.
- `examples/systemd/hive-daemon.service`: `StartLimitIntervalSec=0`, restart
  backoff `RestartSec=30s` → `RestartMaxDelaySec=10min` over
  `RestartSteps=5`. Existing installs need `hive daemon install --force`.

Non-busy repository, corruption, schema, and storage errors still propagate.

**Verification:** focused tests: daemon dispatcher, admission transition
(real `BEGIN IMMEDIATE` lock held by a second connection), attempts store,
daemon service installer, daemon command, and release packaging.

**Open:** silent 17 s startup exits and the leftover `opencode.exe` in the
service cgroup are recorded in [[gaps]].
