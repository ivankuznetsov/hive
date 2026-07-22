---
title: Complete the Rails task behavior boundary
date: 2026-07-20
tags: [web, rails, architecture, tasks]
---

Rails status snapshots now wrap projects and tasks before rendering, so the
dashboard and detail page share `Project`/`Task` behavior. `Task` owns original
idea parsing and title fallback, passable/recovery/terminal state, coding and
generic-workflow dispatch actions, displayed run verbs, and the bounded
worktree diff alongside its existing artifacts, questions, media, and log
reads.

`ApplicationHelper` no longer performs filesystem reads or duplicates Hive's
workflow/action rules. `Tasks::DiffsController#show` delegates the bounded
process-group/tempfile/truncation contract to `Task#diff`, leaving the
controller as a ten-line HTTP resource. Existing dashboard/task/diff behavior
remains covered by focused model and request tests.
