---
title: Refactor patrol command
date: 2026-07-02T12:00:00Z
tags: [command, refactor-patrol, architecture]
---

Added [[commands/refactor-patrol]] for `hive refactor-patrol`: an opt-in,
reporting-only sibling to [[commands/patrol]] that maps feature slices, reviews
schema-shaped refactor theses, scores leverage, flags caps/guardrails, and
persists independent `.hive-state/refactor_patrol/` memory without opening PRs
or enqueueing review tasks.
