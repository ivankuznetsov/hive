---
title: Daemon capacity deferrals now preserve row priority for the tick
date: 2026-08-29
tags: [daemon, scheduler, capacity, fairness, attempts]
---

**Problem:** Durable capacity is evaluated live for every row. A
higher-priority task could be deferred, a short-lived worker could finish
during the same long fleet scan, and a later lower-priority row could then
claim the reopened slot. Because the earlier row was not revisited until the
next tick, repeated short attempts after its scan position could starve it.

**Action:** Added a tick-local capacity fence to the shared full and
changed-task row loop. Global and generic durable capacity deferrals fence all
later dispatch attempts; project and daily caps fence only that project.
Non-dispatch policy classification continues so operational evidence remains
complete.

**Evidence:** Dispatcher regressions reproduce the durable-capacity race,
prove the lower-priority attempt is not admitted, and prove a project-scoped
fence still permits another project to dispatch. The full dispatcher unit
suite remains green.
