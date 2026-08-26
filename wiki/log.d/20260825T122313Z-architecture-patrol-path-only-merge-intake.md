---
title: Make Architecture Patrol merge intake path-only
date: 2026-08-25
tags: [architecture-patrol, merge-intake, github, reliability]
---

- Removed the duplicated per-file and aggregate GitHub patch-size gates from
  merged-PR retrieval, semantic classification, and v3 manifest validation.
- New merge snapshots and manifests retain only path, status, and rename
  origin; discovery reads code from the exact pinned merge worktree.
- Kept old patch-bearing v3 records readable without imposing a size ceiling,
  so existing durable state does not require an in-flight migration.
- Made the classifier and manifest builders enforce path-only output even when
  a legacy-shaped caller supplies patch fields. Legacy snapshot replay compares
  the path-only projection without rewriting persisted state.
- Widened the classification record storage envelope beyond the former 1 MiB
  cap and reject-before-write at that same storage boundary, so large path
  inventories remain readable and the store cannot create a record it cannot
  read back.
- Added a regression matching the 430-file, multi-megabyte patch payload that
  previously kept the chronological merge cursor stuck on one valid PR, plus
  upgrade replay and greater-than-1-MiB path-inventory round trips.
