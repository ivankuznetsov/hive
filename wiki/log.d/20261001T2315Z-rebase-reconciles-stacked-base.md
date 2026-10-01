# 2026-10-01 — Rebase reconciles a stale stacked base

- hivedev C1 was stacked on F1's head (`worktree.yml base_oid` = 82a0490).
  After F1 was squash-merged and the #1503 rebase dropped F1's commits,
  82a0490 was no longer in C1's history. `7-artifacts` outcome evidence then
  failed "controller base is not an ancestor of implementation head"
  (`outcome_evidence_integrity_invalid`).
- `Rebase.reconcile_stacked_base!` moves `base_oid` to the merge base with
  the rebase target whenever the recorded base is no longer an ancestor of
  HEAD. It runs after a successful rebase and on the no-op path, so a pointer
  already left stale heals on the next run. New `GitOps#merge_base`.
