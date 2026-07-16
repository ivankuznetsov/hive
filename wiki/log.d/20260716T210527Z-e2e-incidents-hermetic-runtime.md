---
title: Refresh pending E2E incidents and hermetic runtime coverage
date: 2026-07-16T21:05:27Z
tags: [wiki, e2e, incidents, bundler, tmux, fixtures]
---

- Refreshed [[e2e]] and [[testing]] for commits `140b8fb3`, `1ec7ca4d`,
  `2a4c6fd6`, `608ae0e2`, `af46f520`, and `eb9669fb`. The five incident
  commits actually add pending caller-loss adoption, finalize lifecycle,
  plan-only dependency, repository-routing, and provider-limit retry fixtures;
  each preserves a sibling-owned activation contract and is not passing
  regression evidence while `pending: true`.
- Documented the hermetic runtime boundary from `1ec7ca4d`: scenario overrides
  cannot replace checkout-pinned `HIVE_BIN` / `HIVE_INVOKED_BIN`, copied
  projects force fake Claude into headless mode, and TUI tmux servers start
  inside the unbundled environment. Also recorded the refreshed artifacts-stage
  fake output and current `Tasks · <project>` TUI anchors.
- Updated [[gaps]] because three queued changed-path entries do not match their
  commits' actual diffs. The listed generation-scoped fixture is present in the
  source trees but was introduced by unqueued parent `807929ab`; the actual
  repository-routing addition was absent from the queue metadata. Pending
  finalize/routing declarations still install no `script_gh` sequence, so the
  enabled outer-scenario gap remains open.
- Read `.llm-wiki/config.json`, `AGENTS.md`, `CLAUDE.md`, [[index]], [[gaps]],
  and recent [[log]] entries; searched both the project wiki and configured
  main wiki with `rg` and found no additional cross-project guidance. QMD was
  intentionally not run. Page coverage did not change, so [[index]] was not
  edited.

