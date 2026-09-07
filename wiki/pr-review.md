---
title: Standalone PR review
---

`hive review --pr N --project NAME` creates or resumes a `pr-review` task at `1-review/adhoc-review-pr-N`. Its complete workflow is `1-review` → `2-done`; it reuses the coding workflow's review council, triage, CI and review evidence machinery. There are no development, PR creation, artifact or finalization stages. Review completion makes the task ready to advance; the normal terminal runner completes archival. Development-stage verbs are rejected. Task-run rebasing is skipped.

The owned local worktree uses branch `adhoc-review-pr-N`, matching the task slug. The original PR branch remains unchanged. Review-only behavior is the default; the existing `review.adhoc.fix: true` setting explicitly enables fixes. When fixes publish, Hive targets the original remote PR branch and proves that its current head is the persisted reviewed head. An intervening author commit blocks publication. Successful publication records the new exact head before waiting for CI, allowing subsequent repair attempts. A crash between push and receipt persistence requires identity reconciliation and fails closed. Cross-repository automatic fixes remain unsupported.

Review comments require an open PR in the task repository with matching remote, persisted and local heads. Dropping a borrowed review task does not close its PR.

Re-running `hive review --pr N` migrates a legacy coding task at `6-review/adhoc-review-pr-N` under project and task locks. Migration requires proven ownership of its legacy `hive/review/pr-N` worktree, a clean checkout and an absent replacement branch/destination. It preserves the entire old task under `migration/coding`, assigns a new stable task ID (workflow identity is immutable), creates a fresh review journal and commits the move in the resolved state repository. The old task identity and history remain evidence. A failed state commit restores the old task and branch; a failed rollback retains the recovery backup and reports its path.

Sources: `lib/hive/workflows/pr_review.rb`, `lib/hive/commands/adhoc_review.rb`, `lib/hive/commands/stage_action.rb`, `lib/hive/stages/review/{remote_ci,github_publisher}.rb`, and their focused unit tests.
