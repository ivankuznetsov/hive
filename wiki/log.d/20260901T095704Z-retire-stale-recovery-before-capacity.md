---
title: Retire stale recovery before capacity arbitration
module: daemon
problem_type: bug_fix
tags: [dispatch, recovery, capacity, sqlite]
---

Already-classified `generation_conflict` and `task_identity_conflict` recovery
requests are now retired in the queue cleanup pass. Project and global capacity
fences apply only to runnable work, so an exhausted daily cap can no longer
leave immutable stale recovery receipts resident behind an older request.

The current-task identity checks that depend on a fresh status observation
remain in normal admission. Only conflicts already proven immutable by the
recovery coordinator bypass capacity arbitration.
