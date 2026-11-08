# 2026-09-25 — Attempt supervisors survive SQLite lock contention

- A detached attempt supervisor treated any store error on a heartbeat,
  worker checkpoint, or terminal receipt as a lost lease: it terminated the
  healthy worker group and exited 75 without logging why. Under heavy runtime
  database contention (for example a long `hive digest refresh` holding the
  write lock) a single `SQLite3::BusyException` killed running agents
  (`exit_code=-15`) and left attempts `lost` / `owner_gone`, sometimes after the
  stage had already finished its work.
- Lock contention is now transient for the supervisor: busy heartbeats are
  deferred and retried while the lease is unexpired, and checkpoint/terminal
  writes retry for at most one lease window (`stale_sec`). A lost
  compare-and-swap and non-busy store errors still end the attempt at once.
- When the supervisor does give up, it prints the attempt id and store error
  to stderr so a lost attempt is diagnosable.
