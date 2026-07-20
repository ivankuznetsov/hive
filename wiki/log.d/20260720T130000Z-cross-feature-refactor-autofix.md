---
title: Prefer bounded cross-feature refactors as reviewed fix PRs
date: 2026-07-20
tags: [refactor-patrol, architecture, autofix, review]
---

- Made cross-feature scope normal for architecture refactoring; mapped feature
  slices remain discovery anchors rather than automatic mutation boundaries.
- Kept automatic patches bounded by root confinement, `.hive-state`
  control-plane protection, actual file/diff caps, dependency and
  public-contract guards, secrets checks, canonical receipt paths, and
  trunk-overlap reanalysis across every changed path.
- Allowed docs-only patches without a project docs command to use Hive's
  built-in staged-diff check before entering the normal review workflow.
- Reserved strategic issue routing for oversized, contract-changing,
  dependency-changing, or deterministically unsafe work where human design
  participation is useful before implementation.
