---
date: 2026-07-24
slug: archive-retention-review-fixes
---

- Made terminal run rollback restore the entire pre-run task folder and made
  run/approve preserve a legacy task's earliest credible completion time.
- Kept malformed, deleted, repinned, and dependency-error terminal tasks in
  the lossless archive while freezing one workflow/config generation per
  status refresh.
- Bounded and rotated legacy completion backfill, prevented stale task-folder
  recreation, and kept metadata rewrite guards out of hive/state history.
- Propagated archive-source selection through every task child route and kept
  TUI idle fingerprint work/cache independent of permanent archive size.
