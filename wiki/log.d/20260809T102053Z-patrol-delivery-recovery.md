---
title: Recover Patrol and Architecture Patrol delivery
type: change
date: 2026-08-09
tags: [patrol, architecture-patrol, recovery, validation]
---

- General password detection now requires an assignment delimiter, preventing
  harmless prose such as `password resets` from blocking a validated Patrol
  patch while explicit SQL, XML, and CLI password forms remain protected.
- Architecture Patrol carries structured fix-budget exhaustion into action
  scheduling, defers daily ceilings until the next UTC day, and cools down a
  valid child that made no durable job progress.
- The occurrence safety envelope is 256 effects. Existing 192-cell records
  regain headroom; the daemon reserves the last cell for a durable capacity
  blocker and excludes already-full records from dispatch, so another full
  journal cannot recreate the child hot loop.
