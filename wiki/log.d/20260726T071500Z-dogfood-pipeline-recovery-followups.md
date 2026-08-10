---
title: Dogfood recovery resumes owned progress and refreshes workflow pins
type: fix
date: 2026-07-26
tags: [recovery, migrate, workflows, daemon, dogfood]
---

Current-main dogfood exposed three pipeline blockers after the recovery v2
cutover.

- Universal execute recovery now resumes the exact task-owned worktree even
  when the failed agent left uncommitted progress. Ownership and the execute
  runner's branch, ancestry, cleanliness, and commit completion checks remain
  authoritative.
- `hive migrate` preflights and rebinds managed tasks on the selected package
  generation to its current configuration digest, then cleans unreferenced
  snapshots and reloads a running daemon. Tasks on another package generation
  remain unchanged.
- Task-bound merge reconciliation quietly skips blank and `local:` repository
  identities, while real GitHub repository identity drift still fails closed.
