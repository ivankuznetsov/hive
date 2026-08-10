---
title: Bound durable attempt storage
type: change
date: 2026-08-10
tags: [attempts, storage, migration, operational-status, performance]
---

- Attempt storage now uses a physical v3 layout whose hot `records/` scan is
  independent of permanent proof and cold-log history.
- Final attempts move out of the hot set only after permanent proof, decision
  indexes, and required consumer acknowledgements are durable; point fetches
  preserve historical replay, projection, identity, and closure behavior.
- The forward-only v2-to-v3 cutover publishes an old-binary fence, verifies
  exact corpus and decision parity, checkpoints restartable phases, promotes
  historical finals, and has no dual reader or reverse hydration path.
- Raw logs use digest-sharded cold storage and a persisted 512-entry hourly
  sweep cursor, then expire when the task is archived or three days after
  completion while canonical proof and referenced artifacts remain durable.
- Operational status reads one cached health cell plus current hot counts and
  exposes last-run maintenance deltas with one concise degraded warning.
- A deterministic 30,000-entry proof fixture asserts one hot scan and zero
  proof or cold-log opens/scans, without relying on timing or RSS thresholds.
- A separate deterministic 30,000-log fixture proves maintenance examines only
  one fixed-size page and persists its next cursor.
- The durable CLI ownership replay now follows the public hot-scan and
  point-fetch contract instead of reading a physical attempt-layout path.
