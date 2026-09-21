---
title: Bind independent recovery attempts to post-clear task state
date: 2026-09-04
tags: [attempts, recovery, sqlite]
---

- Independent recovery attempts now derive a fresh ownership generation from
  the task bytes after the retryable marker is cleared, while preserving the
  numeric task-input epoch.
- SQLite admission requires the replacement generation to match the recovery
  request exactly; failed-attempt marker metadata is no longer accepted as an
  alternate generation.
- The provider-limit incident harness exercises the complete failure, marker
  clear, stateless route rotation, worker validation, and successful retry path.
