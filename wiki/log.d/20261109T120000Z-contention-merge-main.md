## 2026-11-09 — Bounded bookkeeping retries merged with main's typed runtime busy

- Merged `origin/main` (#1574 typed `RuntimeControlPlane::Busy`, #1608 daemon
  busy survival, #1610 encode-before-lock publish, #1631 attempt memory cap)
  into the runtime-contention branch.
- `Database#transaction` now raises main's typed `Busy` ("runtime database
  busy, retry", TEMPFAIL) and still emits the branch's writer measurement after
  release. `BookkeepingRetry.busy?` also accepts `SQLiteSupport.busy_error?`, so
  typed busy and `Attempts::RuntimeDatabaseBusy` stay retryable.
- `Attempts::InvalidAttemptRecord` and `RuntimeDatabaseBusy` live in
  `attempts/contracts.rb` with the other repository errors.
- The supervisor keeps the branch's launch-deadline-bounded claim/first
  heartbeat retries instead of main's terminal-budget `with_store_retry`.
- `runtime_connection` composes a caller `after_connect` (the checkpoint-role
  pragma) with the status contention budget. Constructing a `Database` no longer
  checks out the process guard.
- The status CLI gate and the daemon/four-supervisor bookkeeping gate share
  `test/integration/runtime_database_contention_test.rb` as two test classes.
- `ProcessRegistry#reserve!` bounds the SQL wait by its remaining budget only
  when that is below the ordinary 15-second busy timeout, so command
  registration keeps main's retained 15-second wait.
- The typed attempt-path busy surfaces as `RuntimeControlPlane::Busy`, so tests
  that expected a raw `Sequel::DatabaseError` now expect the typed error.
- The real-lock terminalize-exhaustion replay case needs the test process to be
  a session leader (as under rake/CI) for orphan-group custody to match; run
  it under `setsid -w` when invoking the file directly from a shell.
