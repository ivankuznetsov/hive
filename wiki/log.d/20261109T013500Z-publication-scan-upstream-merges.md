## 2026-11-09 — Publication secret scan ignores upstream content merged into the task

- Symptom (PR #1419): `hive publication-reconcile` was blocked by 15
  Betterleaks findings, all upstream test fixtures already on main; 7 were
  re-attributed to the task's merge of `origin/main`. The operator had to add
  exact fingerprints to `betterleaks.ignore`.
- Cause: `SecretScanner.git_findings` scans `--full-history
  --diff-merges=separate base..head`, so a merge commit is diffed against its
  task-side parent and every upstream change the merge brought in is scanned
  as task content.
- Fix: `git_findings`/`git_match?` take `upstream_branch:`; publication
  (open-pr and publication-reconcile via `GithubPublication#ensure_secret_free!`)
  passes the PR base branch. The scan excludes commits already on upstream and
  drops a merge-commit finding only when an upstream-side parent already holds
  the same rule + secret digest at that path. Task commits and conflict-
  resolution content are still reported. Unresolvable upstream / no merge base /
  head already on upstream falls back to the full scan; Git ancestry/commit read
  failures raise `Unavailable` (fail closed).
- `base_conflict` recovery text (`reviews/ci-blocked.md` and `hive run`
  next-action) now says to run `hive publication-reconcile TASK --project P
  --pr URL --head <full sha>` after manually pushing the merge commit, before
  `workflow.retry`.
