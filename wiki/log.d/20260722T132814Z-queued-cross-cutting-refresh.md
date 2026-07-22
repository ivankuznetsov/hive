---
title: Refresh queued cross-cutting branch contracts
date: 2026-07-22T13:28:14Z
tags: [wiki, digest, config, attempts, conditions, patrol, web, e2e]
---

- Inspected all 16 queued commits directly with `git show`, plus branch-tree
  source blobs with `git show <sha>:<path>`. Existing pages already contain
  equal or richer coverage for incident budgets, refactor-patrol identity and
  budgets, durable attempt leases/loss healing, shared TUI/error helpers, Hive
  web naming and kanban transitions, operational stage labels, workflow
  publication, generation-scoped conditions, dependency admission, and the
  v0.5.2 release snapshot.
- Replaced the obsolete dual digest documentation with the queued
  `03fe68af` contract: one registered-repository, Europe/London PR changelist;
  exhaustive GitHub evidence and generated fact/bullet coverage; honest
  optional statistics; Telegram delivery; and sole `hive-digest` v2 JSON.
  Refreshed [[commands/digest]], [[modules/digest]], [[cli]], [[commands]],
  daemon/config/GitHub/template/testing references, [[decisions]], and
  [[index]].
- Documented `0624f58a`'s fail-closed project-key grammar in [[modules/config]]
  and [[modules/workflows]]: static project keys, default-less `gh`, and active
  workflow stage names are accepted; unknown/global-only/non-string keys and
  top-level `reviewers` are rejected before merge, without recursive config
  loading. Added the focused coverage map to [[testing]].
- Recorded in [[gaps]] that those two contracts are still branch snapshots
  relative to this refresh worktree's default source, and that the queued path
  manifests for `02e938cc` and `05b4c137` disagree with their actual diffs.
  Page count stayed 94. QMD was intentionally not run.
