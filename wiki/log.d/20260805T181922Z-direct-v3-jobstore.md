---
title: Make Architecture Patrol JobStore directly v3-only
type: change
created: 2026-08-05
tags: [architecture-patrol, jobstore, storage, compatibility]
---

- Fixed JobStore authority at `refactor_patrol/v3`. Construction and read-only
  queries create no state; the first authoritative mutation lazily creates
  only v3.
- Runtime and module-migration quiescence no longer probe or interpret
  `v2/jobs`. Arbitrary obsolete v2 bytes remain untouched and cannot block or
  override an existing v3 store.
- Removed the unreleased reset command/schema/status projection, fresh-start
  archive and generation machinery, reset-only writer quiescence/fencing, and
  the now-unused managed-directory atomic-exchange primitive.
- Restored `hive-daemon-status.v1` by removing only `job_store_resets`; later
  valid fields and values, including `binary_drift: unreadable`, remain.
- Kept all non-JobStore Architecture Patrol v2 owners, the global terminal
  proofs, and the daemon activation lock unchanged.
