---
title: Memoize unchanged routine task-history folds
date: 2026-09-01
tags: [task-journal, status, daemon, performance]
---

- Added a bounded, thread-safe, process-local LRU for unchanged routine task
  history results. Cache identity includes the authoritative journal file and
  marker/task semantics, so appends and replacements miss without adding a
  persisted projection or checkpoint.
- Kept the nonblocking shared task-journal lock in front of cache lookup. Writer
  contention now reports typed `busy` state and remains scheduler-owned
  `condition_task_history_unavailable`; a cached projection is never served
  while the writer holds the lock.
- Replaced truncation message sniffing with `JournalTooLarge`, so byte/event
  limit failures alone set `truncated`, and recorded the remaining unbounded
  journal-growth/compaction gap.
