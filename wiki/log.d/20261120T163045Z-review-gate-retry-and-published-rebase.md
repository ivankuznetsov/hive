---
title: Operator-remediated review gate retries make progress; published review branches are never auto-rebased
type: fix
created: 2026-11-20
updated: 2026-11-20
tags: [recovery, review, base-conflict, rebase, publication, incident]
---

todero #100 (`shopping-lists-quantities-units-and-261105-54f2`) sat in
6-review with `REVIEW_CI_STALE gate=github reason=base_conflict` after the
operator did what `reviews/ci-blocked.md` asked: merge commit `6bb0083`,
fast-forward push, `hive publication-reconcile`, `workflow.retry`. Two bugs
held it there.

**1. The retry fingerprint could not see the remediation.**
`RecoveryCoordinator#failure_fingerprint` hashed the marker's reason,
provider, status, message digest and a progress revision that was non-empty
only for `dirty_worktree`. A `base_conflict` marker keeps its attrs until the
stage re-runs. On 2026-11-19 the healer retried the unmerged conflict five
times (15:47Z to 16:24Z), each re-running the GitHub gate. The operator's
post-merge retry at 17:22Z therefore counted as identical failure six at the
ladder ceiling and was written already parked (`deterministic_failure`,
`escalation_tier=parked`). The daemon replayed that park every tick.

- The fingerprint's progress revision now also covers review CI-gate blocks
  that no Hive agent repairs: `REVIEW_CI_STALE`/`REVIEW_ERROR` with a `gate`
  and reason `base_conflict`, `mergeability_unknown`,
  `required_checks_missing`, or `required_checks_unknown`. It records the task
  branch HEAD (`git rev-parse` in the `worktree.yml` path) and the publication
  record's `published_head_oid` (falling back to `head_oid`). A merge, push,
  or reconcile is a changed input, so the retry starts a fresh series and a
  fresh retry ladder. A retry at the same heads is still identical and parks
  after three at the ceiling. Red local CI (`REVIEW_CI_STALE` without a
  reason) is excluded, because its CI-fix agent commits on every run.
- The dispatched retry already re-runs the gate: `RecoveryCoordinator#resume`
  clears the marker before `hive review … --from 6-review` runs, and the
  review runner then re-queries GitHub mergeability. Only a direct `hive run`
  with the marker still set prints the instructions and exits. Tests pin both.

**2. The auto-rebase pre-step rebased a published review branch.** At
16:23Z (a healer retry) and 17:05Z (a manual `hive run`), `Hive::Rebase`
counted `HEAD..origin/main` (`default_branch: main`), found the branch behind
(the merge commit came at 17:13Z), and dispatched the conflict agent, which
failed on Muse's quota. The worktree's stale upstream (the deleted stacked
prerequisite branch) was never consulted. The fault was rebasing a published
PR in review at all: a success would have rewritten the branch and
lease-pushed over the PR, against review's merge-commit-only recovery.

- `Hive::Rebase.perform` returns `Result.skipped(:published_review_branch)`,
  before any fetch, when the task's stage runs the review runner and its PR
  is published (`github-publication.json` exists or `pr.md` has a `pr_url`).
  The new reason is in the closed `hive-run.v2` enum, `hive rebase-status`
  reports it, and the skip is silent like the other skip states.
- A branch that already contains `origin/<default_branch>` stays a no-op.
  "Behind" is never measured against the upstream. A real-git test with a
  stale stacked upstream pins both rules.
- Not changed: the conflict agent resolves `execute.agent` from the config at
  run time, not from the captured implementation identity. The Muse runs
  predate the Grok stand-in written on 2026-11-20 16:08Z. Recorded in
  [[gaps]].

Pages: [[modules/daemon]], [[commands/daemon]], [[modules/rebase]],
[[commands/run]], [[commands/rebase-status]], [[stages/review]],
[[state-model]], [[publication-recovery]], [[gaps]].

Tests: `test/unit/daemon/recovery_coordinator_test.rb` (a reconciled merge
clears the park and the marker; same heads stay identical; fingerprint scope),
`test/integration/run_review_test.rb` (a cleared `base_conflict` re-runs the
GitHub gate on the merged head and completes), `test/unit/rebase_test.rb`
(published review PR never rebased; guard scope; stale-upstream no-op),
`test/unit/commands/rebase_status_test.rb`, `test/unit/schema_files_test.rb`,
`test/unit/commands/run_no_rebase_test.rb`.
