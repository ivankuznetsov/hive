# 2026-09-29 — Auto-rebase skips a squash-merged dependency's commits

- hivedev C1 and F2 were built on F1's branch. F1 was then squash-merged, so
  both branches still started with F1's original commits. Hive's auto-rebase
  replayed those onto the squash commit, conflicted, spent all
  `MAX_CONFLICT_RESOLUTIONS` agent dispatches, and published both PRs with a
  stale base (GitHub: CONFLICTING).
- `GitOps#squash_merged_prefix(ref)` finds the newest branch commit whose
  cumulative change since the merge base equals one commit that landed on
  `ref` (same tree or same `patch-id --stable`). The scan is bounded by
  `SQUASH_SCAN_LIMIT` = 200 commits per side. `Rebase.run_rebase` then runs
  `git rebase --onto <ref> <that commit>`, replaying only the dependent's own
  commits, and prints a note to stderr.
- `GitOps#rebase_onto` takes an optional `upstream:`.
