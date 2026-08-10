---
title: Roll over saturated Architecture Patrol occurrences
type: change
date: 2026-08-09
tags: [architecture-patrol, occurrence, journal, recovery]
---

- Architecture Patrol now finalizes and projects a saturated occurrence
  segment, then advances the job to an empty next-generation occurrence rather
  than becoming permanently blocked at the effect limit.
- Rollover is recovery-safe: a successor reserved before interruption is bound
  to its derived predecessor, which must become terminal before the job pointer
  advances.
- Finished job transitions retain their historical occurrence identity; only
  the current segment participates in effect recovery, and every active claim
  must still match that current occurrence.
- Duplicate merged-PR intake after rollover returns the already-authoritative
  job without writing a second enqueue effect.
- The scheduler resolves an expired current-segment claim before rolling and
  revalidates migration owner, epoch, and admission under the shared fence.
- Aggregate effect transitions are capped per claim generation, so retained
  predecessor history cannot exhaust a successor segment's transition budget.
