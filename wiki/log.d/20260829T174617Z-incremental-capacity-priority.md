---
title: Changed-task ticks now honor the full-scan capacity queue
date: 2026-08-29
tags: [daemon, scheduler, capacity, fairness, incremental]
---

**Problem:** The full status-row scan correctly fenced later rows after a
higher-priority capacity deferral, but a worker completion could trigger a
changed-task tick before the next full scan. That bounded delta contained only
the completed task's successor, so it could immediately reuse the slot without
reconsidering older capacity-deferred rows.

**Action:** Persist the full scan's global and per-project capacity-fence
snapshot across intervening changed-task ticks. A successful full scan replaces
the snapshot from a clean starting point; delta ticks inherit and extend it.
Project-scoped fences continue to permit unrelated projects to dispatch.

**Evidence:** Regressions reproduce both the global successor bypass and the
project-scoped variant against the prior implementation. The global successor
now remains fenced until a full rescan, while another project still dispatches
through a project-only fence.
