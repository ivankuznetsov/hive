---
date: 2026-06-27T08:32:47Z
slug: adhoc-pr-review
pages: [cli, commands/stage_action, modules/config, modules/gh, modules/pr, modules/worktree, stages/review, state-model]
---

## review — ad-hoc PR review entry point

`hive review --pr <n>` now creates or reuses a synthetic
`6-review/adhoc-review-pr-<n>/` task for an existing GitHub PR and then runs the
normal review StageAction path. The bare numeric form remains a task target:
`hive review 197` still resolves task id `197`.

The new path resolves a registered project from `--project NAME` or the current
directory, requires the project's `.hive-state` to exist, fetches PR metadata
with `gh pr view`, materializes the PR head through shared
`Worktree.materialize_pr`, writes normal review sidecars with `source: ad-hoc`,
and refuses to shadow another Hive task that already owns the same PR number.

Review-stage behavior now treats `source: ad-hoc` specially:
`review.adhoc.reviewers` overrides the normal reviewer list when set, falls
back to `review.reviewers` when nil, and `review.adhoc.fix` defaults false so
accepted findings pause as `REVIEW_WAITING reason=adhoc_fix_disabled` instead
of pushing fixes to someone else's PR.

Updated [[cli]], [[commands/stage_action]], [[state-model]],
[[stages/review]], [[modules/config]], [[modules/pr]], [[modules/gh]], and
[[modules/worktree]]. Coverage includes PR identifier parsing, cwd/project
resolution, PR metadata parsing, PR-head materialization, ad-hoc enqueue
collision/reuse paths, review-stage ad-hoc reviewer/fix gates, CLI routing, and
the CLI-to-enqueue-to-StageAction integration.
