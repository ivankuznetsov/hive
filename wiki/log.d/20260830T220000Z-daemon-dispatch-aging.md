---
title: Daemon dispatch aging prevents early-stage starvation
date: 2026-08-30
tags: [daemon, scheduler, fairness, capacity]
---

- Kept later-workflow-stage-first dispatch for fresh rows while adding one
  priority step per 30 minutes since the task state file changed.
- Old eligible plan and retry rows now rise above a continuous stream of newer
  review, artifact, and publication work instead of remaining behind the
  capacity priority fence indefinitely.
- Missing and future mtimes receive no boost; equal effective priorities keep
  the internal status graph's stable order.
