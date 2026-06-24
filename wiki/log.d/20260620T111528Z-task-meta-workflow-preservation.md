---
title: Task meta updates preserve workflow
date: 2026-06-20T11:15:28Z
area: task
---

## Task meta updates preserve workflow

`Hive::TaskMeta.write` now accepts an optional `workflow:` selector, and both
`update_display_name` and `update_id` preserve the existing selector when they
rewrite `meta.yml`. This prevents display-name generation or daemon id backfill
from silently dropping a task-level workflow override.

Updated [[modules/task]] and pinned the behavior in `test/unit/task_meta_test.rb`.
