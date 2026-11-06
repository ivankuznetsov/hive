# 2026-11-06 — Review does not run agents for a merged or closed PR

**Action:** Fixed review redispatch for tasks whose PR the operator had already
merged (inbox task `review-redispatches-tasks-whose-pr-261105-5b45`). On
hivedev, clearing C5's REVIEW_ERROR after squash-merging hivedev#23 started a
full review pass, and the agent-run-isolation spike's (hivedev#24) CI-fix
phase committed onto the merged branch, which blocked `hive archive`.

**Findings:** The PR merge watcher had durably recorded both merges as
`pull request outcome changed` (`pr_state: delivered_elsewhere`), but only
`merge_reconciliation_blocks_recovery?` consulted watcher state, only for
REVIEW_ERROR rows, and only from the watcher's in-memory poll cache, which is
keyed by marker generation and drops the state when the marker changes.
Nothing on the dispatch or review-entry path read PR outcomes.

**Change:** New `Hive::PullRequestOutcome.latest(task_folder)` replays the task
journal for the latest `pr_observed`/`merge_observed` record matching the
current `pr.md` URL (merged / delivered_elsewhere / ambiguous ⇒ merged;
closed / closed_unmerged ⇒ closed; anything unreadable ⇒ nil).
`Dispatcher#dispatch_or_block` holds coding `6-review` rows with a settled PR:
`:skipped reason=pull_request_merged` or `:blocked
reason=pull_request_closed_unmerged`, with an operator-owned operational
disposition (`waiting_on_you`). `Review.run!` pre-flight returns
`:pull_request_merged` / `:pull_request_closed_unmerged` before any CI-fix,
reviewer, triage, or fix agent, leaving the marker untouched. No observation
keeps the previous behavior. Remaining limits are in `wiki/gaps.md`.
