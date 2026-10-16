# 2026-10-16 — `hive new` reports an unknown project before probing receipts

- With `--idempotency-key`, `New#keyed_call!` probed receipt storage
  (`CommandOperation.receipts_installed?`) before checking that the project
  exists. On a host without the runtime control plane (a fresh workspace,
  hivedev's compat sandbox), an unknown project therefore failed with a
  storage error instead of `ProjectNotFound`. This was the last blocker on
  hivedev's Hive pin raise (plan-review Q1).
- `keyed_call!` now calls `require_project!` first. `perform_call!` reuses the
  same helper. This follows #1518, which did the same for malformed keys.
