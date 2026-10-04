---
title: Require task ids at capture
type: fixed
date: 2026-10-02
---

Current-format task creation now fails closed when the runtime control plane
cannot allocate a numeric task id. Ordinary new-task capture, shared controller
capture, and ad-hoc review all use `Hive::TaskCounter.next!`; their existing
candidate rollback removes task folders and temporary worktrees on failure.
This prevents a transient allocation outage from publishing an id-less task
that durable attempt admission rejects after the retired daemon backfill path
can no longer repair it.
