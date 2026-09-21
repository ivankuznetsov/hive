---
title: Terminal workflow actions drain before new same-stage work
type: change
date: 2026-08-24
tags: [daemon, scheduler, patrol-fix, concurrency]
---

The daemon now prioritizes terminal advance actions over fresh agent runs when
both rows occupy the same workflow stage. This prevents a large Patrol Fix
inbox from consuming every project slot while accepted findings wait to move
from `1-inbox` to `2-fix`; status order remains stable within each action class.
The priority also spans unrelated queued requests and bounded changed-task
ticks. Incremental ticks use the full scan's in-memory advance index rather
than reading the complete status graph again, while a same-task queued request
continues to win its slug and suppress duplicate row dispatch.
