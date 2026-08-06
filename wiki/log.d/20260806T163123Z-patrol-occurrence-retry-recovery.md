---
title: Recover saturated Patrol retry occurrences
type: change
date: 2026-08-06
tags: [patrol, architecture-patrol, recovery, worktree]
---

- Ordinary feature maps now persist through one digest-bound, retry-safe batch
  effect instead of one effect per feature.
- Retryable Architecture Patrol actions use one shared one-hour runner and
  scheduler cooldown, and the occurrence envelope accepts existing 128-effect
  records with bounded room to settle and recover.
- Exact refactor worktrees whose Git registration survived but whose `.git`
  pointer disappeared are preserved under `.hive-quarantine/`; only their
  stale registration is removed before reattaching the validated branch, and
  a second unresolved quarantine fails closed rather than growing disk use.
