---
date: 2026-07-17
summary: Close exact-head durable-attempt admission and output gaps
---

- Serialized capacity scan and reservation creation with one shared admission
  lock outside the per-generation lock, preventing different task generations
  from simultaneously consuming the same final capacity slot.
- Recomputed the admitted generation under the task lock immediately before
  run/approve side effects, so a task or dependency change between dispatch and
  worker start fails retryably instead of executing stale work twice.
- Tracked replayed stdout bytes and routed non-zero durable JSON outcomes with
  no worker document through the command's normal versioned error envelope.
- Preserved nullable process-identity keys on compatibility backfills so their
  stored records satisfy the published attempt schema.
- Clarified that durable context is an application ownership boundary: Hive's
  process-level state-root environment remains trusted, and stronger same-UID
  isolation requires a separate broker/protected authority.
