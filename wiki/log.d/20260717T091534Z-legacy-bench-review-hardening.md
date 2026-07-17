# 2026-07-17 — Harden legacy bench migration review findings

- Made the legacy descriptor archive, packaged runtime replacement, and
  `default_workflow: bench` rebind one commit-locked hive-state transaction.
- Reset staged migration paths before filesystem rollback and restore config,
  descriptor, and prior runtime after rejected commits or Ctrl-C.
- Retain and report the previous runtime backup when deletion of a failed new
  runtime does not converge, preventing backup nesting or overwrite.
- Reject symlinked legacy workflow roots, descriptors, and instruction roots
  before archive copying, with realpath confinement beneath hive state.
- Added fault-injection coverage for rejected-commit retry, both interrupt
  windows, symlink escape attempts, archive tracking, automatic cache reset,
  and rollback deletion failure.
- Deferred asynchronous interrupts across each mutation/bookkeeping pair and
  commit-result capture, preserving a migration that was already committed.
- Required a clean hive-state index and made the config pathspec conditional on
  an actual rebind so idempotent refresh cannot absorb unrelated config edits.
- Published instruction archives from private staging and refused a raced
  symlink destination without traversing it.
- Bound legacy classification and archival to the same no-follow descriptor
  inode/content snapshot, rejecting atomic replacement by a custom descriptor.
- Pinned the validated workflows directory for archive and rollback operations,
  then rejected logical-parent replacement before commit so an external symlink
  cannot redirect migration writes or deletion.
- Replaced the final descriptor path deletion with atomic quarantine,
  snapshot revalidation, and no-clobber archive publication; a reappearing
  custom descriptor is preserved and the legacy copy is retained for recovery.
- Added a post-staging Git invariant for the pinned descriptor path and index,
  preventing a replacement at commit entry from being included in migration.
