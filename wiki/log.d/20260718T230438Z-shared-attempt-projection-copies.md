## 2026-07-18 — Complete shared durable value copying

- Replaced the remaining recursive `deep_copy` implementations in durable
  attempt records and task projection with `Hive::StringifyKeys`.
- Migrated attempt-store transition callers that had treated
  `Record.deep_copy` as a namespace utility, preserving new-container,
  string-key, and scalar-value semantics.
- Verified attempt records/transitions, projection storage, condition
  reconciliation, action gates, generation, and the shared transform together:
  72 runs, 287 assertions, zero failures, zero errors, and zero skips.
