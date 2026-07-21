---
title: Share fail-soft task id allocation
type: changed
date: 2026-07-18
---

`Hive::TaskCounter.next_or_nil` now owns the capture-time policy that turns
counter-lock contention into a null task id. New-task capture, ad-hoc review,
and patrol review handoff keep their existing durable fallback for later daemon
backfill, while migration and the backfiller retain strict `next!` allocation.
