---
title: Persist the unified Patrol Fix authority cutover
date: 2026-08-21
tags: [patrol, architecture-patrol, patrol-fix, migration, daemon]
---

- Added the restart-safe `preflight` → `fenced` → `applying` → `committed`
  cutover for ordinary and Architecture Patrol findings using the existing
  Patrol owner epochs, migration lock, and source handoff outboxes.
- Added read-only complete inventory/preflight commands and confirmed apply,
  status, and pre-effect rollback commands. Migration re-reads source records,
  materializes each semantic group once, acknowledges source members last, and
  verifies both authorities before commit.
- Reconstructed both committed source adapters and their shared admission/task
  factories in the existing daemon. Provider quota retry timestamps dominate
  local retry backoff; discovery allowances remain separate from workflow
  concurrency.
- Fenced legacy downstream task, local worktree/branch, issue, PR, terminal
  acknowledgement, and manual Architecture `--pr` manifest effects. No new
  epoch, outbox, daemon, token budget, sandbox, GitHub issue mutation, or v2
  writer was introduced.
