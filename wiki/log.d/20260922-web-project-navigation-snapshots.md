---
title: Keep project navigation on the saved status frame
date: 2026-09-22
tags: [web, status, loading, cache, completed-tasks]
---

- Restore the non-blocking status contract for normal project Board and Grid:
  history rebuilds and daemon service/version checks run on the existing poller.
- Persist requested completed history and workflow column definitions with the
  active display frame, reusing Cable change tokens and reconnect catch-up.
- Preserve Done cards during expiry, restart and failed history refreshes;
  prefer fresh active state for reopened tasks and reject relocated history.
- Keep default columns on empty fleet boards and retain the last valid Done
  grouping with a warning when a workflow descriptor cannot be reloaded.
- Cover HTTP rendering while a history refresh holds the workflow registry
  lock, expired caches, saved page validation, and unchanged-frame suppression.
- Explicit Archive reads retain their on-demand, complete-history behavior.
