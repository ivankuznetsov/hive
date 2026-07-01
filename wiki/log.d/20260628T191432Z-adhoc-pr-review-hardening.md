---
date: 2026-06-28T19:14:32Z
slug: adhoc-pr-review-hardening
pages: [cli, modules/gh, modules/worktree, modules/pr, stages/review]
---

## review — ad-hoc PR review hardening (6-review fix pass)

Follow-up hardening on the `hive review --pr <n>` ad-hoc entry point:

- **Fix-off contract now covers Phase 1 CI-fix.** With `review.adhoc.fix`
  disabled (the default), the CI-fix agent is skipped entirely — a configured
  `review.ci.command` can no longer spawn a fix agent or auto-commit on a
  borrowed PR worktree. The wiki wording shifted from "pushing" to
  "committing" because the review stage never pushes; Phase 4 commits stay
  local on `hive/review/pr-N`.
- **Empty `review.adhoc.reviewers: []`** now warns (mirroring the patrol
  empty-reviewers warning) so a silently unreviewed PR is observable.
- **Reuse is documented as pinning to the first-run head** ([[cli]]): re-running
  after a PR re-push re-reviews the original head; `hive drop` + recreate to
  pick up new commits. Reuse also validates the worktree dir still exists and
  matches `source` case-insensitively.
- **Enqueue robustness:** `hive_state_path` resolves through
  `Config.project_hive_state_path`; the PR-head fetch in
  [[modules/worktree]] `materialize_pr` uses the shared non-interactive fetch
  env; `Pr.identifier_to_number` ([[modules/pr]]) rejects non-positive
  numbers; a pre-materialize orphan-worktree sweep lets a single retry
  self-heal; and `cleanup_failed_task!` is self-guarding (its own errors
  cannot mask the original failure, and surviving residue is warned).
- **Docs:** [[modules/gh]] now documents the load-bearing `chdir:` kwarg on
  `pr_metadata` that makes `--project NAME` query the right repository.

Updated [[cli]], [[stages/review]], [[modules/gh]].
