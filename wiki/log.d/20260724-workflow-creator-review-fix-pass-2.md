## 2026-07-24 — Workflow creator review fix pass 2

- Preserved strict no-write workflow validation and minimal-init preview at
  executable startup, kept minimal init free of scheduler timers, rejected
  managed-path and scaffold symlink redirection, and added a locked
  `hive workflow commit ID` path for populated owner-authored graphs.
- Made human decisions reject non-local or symlinked completion artifacts,
  record self-target outcomes with a fresh decision identity, and return
  idempotent no-ops for matching concurrent retries.
- Made task creation fingerprint owner-authored workflow bytes, fail closed on
  corrupt metadata, use the canonical workflow-mutation/state-commit lock
  order, and clean both owned candidates and staged index entries on failure.
  Applied the same exact-path index rollback to failed workflow scaffold and
  populated-graph commits.
- Specified exact POSIX request quoting and deterministic retry-key derivation,
  then expanded hermetic creator acceptance to cover version/confirmation
  refusals and durable populated-graph commit evidence.
