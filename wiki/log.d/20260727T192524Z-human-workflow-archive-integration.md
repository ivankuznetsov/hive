## 2026-07-27 — Human workflow archive integration

- Routed completed human stages through the shared `archived` action and
  descriptor retention path instead of maintaining a human-only completion
  bucket.
- Stamped `meta.yml completed_at` from the durable decision timestamp and made
  state plus metadata rollback together on commit failure or interruption.
- Refused symlinked human decision-state reads with no-follow inode checks.
- Made strict no-write startup routing select the actual top-level command, so
  a workflow id named `workflow` cannot trigger scheduler reconciliation during
  minimal-init preview and option placement cannot hide workflow validation.
- Bound idempotent attachment fingerprints and task assets to one private byte
  snapshot, with a final digest check before metadata is committed.
- Treated a dangling `.hive-state` symlink as an occupied minimal-init target
  instead of allowing initialization to reach an unsafe path.
- Made workflow scaffolds claim their instruction directory and descriptor
  exclusively, and limited rollback to paths the invocation actually created,
  so a concurrent creator cannot be overwritten or deleted.
- Extended task creation, workflow scaffolding/commit, and minimal-init rollback
  boundaries to interrupts as well as ordinary exceptions.
- Rechecked owner-authored workflow content inside idempotent creation before
  reuse and metadata publication, aborting raced descriptor/instruction edits.
