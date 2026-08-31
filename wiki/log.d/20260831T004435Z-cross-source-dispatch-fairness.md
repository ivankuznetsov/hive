---
title: Daemon dispatch requests and task rows share admission priority
date: 2026-08-31
tags: [daemon, scheduler, fairness, dispatch-queue, capacity]
---

**Problem:** Request FIFO and task-row aging were fair only inside their own
lanes. The daemon drained every durable request before considering direct task
rows, so a persistent active request backlog could consume each newly opened
slot and indefinitely strand an old runnable plan or retry.

**Action:** Interleave unrelated requests and direct rows with one
stage-plus-age priority. Requests keep FIFO, equal-score, and same-task
precedence. Both sources now propagate global and project capacity fences to
the other for the rest of the authoritative scan.

**Evidence:** Dispatcher regressions prove an old direct row outranks a newer
request for the last slot, same-task requests still launch exactly once, and
global capacity fences flow in both directions without a second gate call.
Project and daily fences remain scoped to their project in both directions,
and invalid or expired requests are cleaned before any capacity-fence exit.
