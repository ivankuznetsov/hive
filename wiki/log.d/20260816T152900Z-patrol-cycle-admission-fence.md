---
title: Ordinary Patrol cycle admission fence
area: patrol
---

Ordinary Patrol's full-cycle lock now fences daemon occurrence recovery and
reservation through a nonblocking descriptor-safe admission check. A scheduled
recovery cannot adopt and finalize the occurrence of a live manual worker, and
a manual mutating cycle refuses a daemon occurrence that won the race first.
Read-only dry runs no longer allocate occurrence-journal records.
