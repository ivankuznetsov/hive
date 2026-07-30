---
title: Close fresh-start and Patrol publication recovery gaps
type: change
created: 2026-07-30
tags: [architecture-patrol, patrol, jobstore, recovery, publication]
---

- Removed the last `job_store.schema_v2_import` trigger and
  `schema_v2_import` outcome from Patrol evidence, shadow comparison, and their
  published schemas. Released JobStore v2 now has one transition only:
  explicit opaque archival followed by an empty v3 start.
- Removed unused managed-directory quarantine/replacement primitives that
  served the abandoned conversion/restore design. Atomic directory-to-marker
  exchange remains the reset primitive.
- Made an existing publication binding or uncertain-effect seed fail closed
  when its exact validated patch receipt is missing, mismatched, or unreadable.
  Recovery preserves the checkout and does not reset the branch, rerun the fix
  agent, write a replacement patch, or mint a new patch identity.
- Made terminal PR recovery retain its exact worktree while the publication
  outbox is pending or the durable binding is absent/conflicting. Cleanup is
  allowed only when the complete binding derived from the terminal receipt
  matches the attempted patch and is outside the retryable states. A
  projection-crash restart test proves one push and one PR creation.
- Made the deterministic v2 archive name part of generation-presence
  detection. An archive whose public reset marker is missing now blocks status
  and runtime admission instead of being mistaken for a fresh project.
- Added crash, replay, malformed-projection, typed-error, lock, daemon
  readiness, status degradation, and multi-occurrence publication recovery
  coverage without running a live JobStore reset.
