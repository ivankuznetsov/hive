# 2026-10-16 — `hive new` checks the project before the key

- #1547 moved the project check ahead of the receipt probe, but `New#call`
  still validated the idempotency key first. `hive new nosuch TEXT
  --idempotency-key= --json` (the CLI passes an empty key through) therefore
  exited 64 `IdempotencyConflict` instead of reporting `ProjectNotFound`.
  hivedev's compat suite caught it at the 30ed2c7 pin raise.
- Keyed calls now check project, then key, then receipt storage. An unknown
  project is reported whatever the key looks like, and a malformed key is
  still rejected before receipt storage is opened (#1518).
