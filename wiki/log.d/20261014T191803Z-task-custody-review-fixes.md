---
title: Task custody review fixes
date: 2026-10-14
tags: [task, lifecycle, rollback, plan-review, workflow-package]
---

- Kept legacy slug-less task observations valid after Hive's own metadata normalization.
- Made stale task outcomes retryable and preserved dependency-admission diagnostics at observation boundaries.
- Kept approve, decide, plan review, and managed workflow rollback/setup paths non-creating and identity-fenced.
- Preserved the surviving copy after cross-device moves and rejected unexpected destination identities.
- Bounded plan-review orchestration locking and reported incomplete guarded rollback through typed command errors.
- Restored fail-soft task-id allocation and the original advisory incident-test budget.
