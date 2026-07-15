---
title: Default merged-PR digest and line stats
type: change
date: 2026-07-15
---

- Made `merged-prs` the shared absent-config source for manual and daemon
  digests, with `digest.source: shipped` and `--source shipped` preserving the
  agent-written shipped-task report as an opt-in.
- Reused the registered-project registry for automatic merged scope and made
  zero resolved repositories a configuration error before collection or send.
- Added best-effort additions, deletions, and commit totals to merged reports
  through the shared digest stats/footer path. The known PR count always
  renders, including valid zero-merge days, while Lines and Commits disappear
  only when no PR stats can be measured.
- Preserved the existing v1 JSON shapes and honest identities:
  `hive-merged-pr-digest` for merged runs and `hive-digest` for shipped runs.
