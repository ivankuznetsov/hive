---
date: 2026-07-25
title: Task-local web reads became bounded and fleet-independent
tags: [web, status, diff, polling, reliability]
---

- Task routes now resolve one registered target without invoking fleet status.
- `StatusFeed` owns single-flight scans, latest-good degraded state, stable
  freshness tokens, and observable scan counts.
- Task diff validates owned worktrees and returns bounded, redacted, typed
  committed/staged/unstaged/untracked results.
- Status and task pages distinguish unavailable/degraded data and disable stale
  mutation controls; browser polling is abortable, visibility-aware, and
  single-flight.
