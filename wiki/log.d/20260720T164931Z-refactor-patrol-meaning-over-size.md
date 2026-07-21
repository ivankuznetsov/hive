---
title: Let architecture value determine refactor PR scope
date: 2026-07-20
tags: [refactor-patrol, architecture, autofix, policy]
---

- Removed `max_files` and `max_diff_lines` from Refactor Patrol defaults,
  policy capture, discovery schema requirements, prompts, mutation guards, and
  publication receipt validation.
- Refactor theses now describe one complete coherent architectural resolution;
  they are not rejected, down-ranked, split, truncated, or routed to an issue
  because of estimated or actual patch size.
- Kept behavior-preservation validation, protected-path and secret checks,
  dependency and public-contract guards, root confinement, exact-base
  worktrees, trunk-overlap reanalysis, and normal PR review as the mutation
  safety boundary.
- Legacy persisted policy keys and thesis size flags remain readable for safe
  recovery. Size-only flagged findings are promoted back to accepted action
  candidates, while any remaining safety reason keeps the finding flagged.
- Published v1/v2 thesis and report schemas remain frozen for compatibility;
  new PR-scoped discovery and action output uses the size-free v3 contracts.
