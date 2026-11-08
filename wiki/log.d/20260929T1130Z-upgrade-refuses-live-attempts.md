# 2026-09-29 — Quiescence upgrade refuses live attempts

- During the dogfood schema-1 → 2 conversion, the services were stopped but
  two attempt supervisors (their own `Hive durable attempt` systemd units)
  were still running. `QuiescenceUpgrade` took the fences, swapped the
  database file, and left one supervisor heartbeating into the unlinked copy.
  The live database kept the attempt `running` with no further writes.
- `QuiescenceUpgrade#call` now refuses with `live_attempts_present` (listing
  attempt id, slug and heartbeat) while any `running` attempt has heartbeat,
  or started, within `LIVE_ATTEMPT_WINDOW_SEC` (900s, above the supervisor's
  600s SQLite-busy tolerance). The check runs before the ownership verifier
  and again under both fences, and a refusal leaves the source and proof
  untouched. Older `running` rows are left for `hive daemon resume`
  reconciliation.
- New read-only `Database#quiescence_upgrade_running_attempts`. The migration
  guide notes that durable attempt units outlive the services.
