---
title: Preserve Patrol Fix terminal advances in shared dispatch priority
type: fix
date: 2026-08-31
tags: [daemon, scheduler, patrol-fix, concurrency]
---

Patrol Fix `ready_to_advance` transitions now receive a half-step priority
tie-break within an equal stage-and-age lane. This keeps accepted findings
moving ahead of fresh same-stage work while retaining the newer shared
row/request arbitration, FIFO request constraints, and capacity fences.
