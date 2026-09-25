# 2026-09-25 — Quiescence CLI, status, and explicit resume

- `hive daemon quiesce` and `hive daemon resume` now expose strict v1 JSON
  envelopes with one finite positive installation-wide deadline (600 seconds
  by default) and typed usage, storage, migration, busy, ownership, and
  timeout outcomes.
- Non-paused quiesce responses that leave admission closed carry the exact
  explicit-resume obligation. A non-disruptive ownership refusal while
  admission remains open does not.
- Daemon status now reports runtime lifecycle separately from daemon PID
  liveness, validates the generation-bound flush proof, applies the same
  advisory ownership predicate as quiesce entry, and downgrades paused when a
  retained process is live or cannot be verified.
- Resume invalidates the old proof before mutation, reconciles while admission
  remains closed, reopens only by generation CAS, then reports managed-service
  restoration independently so a partial restart cannot obscure admission
  state.
