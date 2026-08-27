---
title: Bound Patrol Fix pending admission reads
type: change
date: 2026-08-23
---

- Added one compact Patrol Fix pending index containing only occurrence ids and
  their next eligible time.
- Changed scheduler reads to open at most the requested admission record limit
  instead of parsing every record in the project inventory.
- Kept authoritative admission records and the index synchronized under the
  inventory lock with crash ordering that can leave only safe early entries;
  selected stale entries repair from their authoritative record without
  consuming the entire ready batch. Contended reads skip one daemon tick.
- Added explicit, idempotent index construction to `hive migrate`. Runtime
  ticks fail closed on an unindexed existing store and never scan-rebuild it.
- Made a live old-daemon cutover synchronous and followed it with one final
  explicit index pass. Ordinary Patrol retries idempotent publication for an
  active finding whose first admission handoff was interrupted.
