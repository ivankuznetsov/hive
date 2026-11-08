# 2026-10-27 — Evidence closure accepts worktree content already on the default branch

- `hive archive TARGET --reason already_delivered --evidence …` no longer
  blocks on `unique_worktree_changes` when the task worktree's commits are
  not ancestors of the PR head but their content already landed, for example
  a review fix that was never pushed and was delivered through a follow-up
  PR after a squash merge. The check merges HEAD into the default branch with
  `git merge-tree --write-tree` and treats an unchanged tree as delivered;
  conflicts or any change still block. See [[state-model]].
