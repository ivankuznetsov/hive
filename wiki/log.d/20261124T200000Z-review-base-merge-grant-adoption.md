## 2026-11-24 — Review adopts the operator's base merge under an active grant

- Retrying a granted review after the documented base-conflict merge no
  longer wedges. The hosted gate parks a granted review as `REVIEW_CI_STALE
  gate=github reason=base_conflict`, and `reviews/ci-blocked.md` asks for
  `git merge --no-ff origin/<base>` plus `workflow.retry`. That merge changed
  the head the grant approved, so `RecoveryCoordinator#resume` blocked the
  retry as `review_grant_evidence_changed` and CI and review never restarted.
  Example: uk-new-companies task 43513 on 2026-11-24, unblocked only by a
  manual rewind.
- New `Hive::ReviewBaseMergeAdoption` runs in `resume` under the task lock,
  after the fast-forward adoption and before grant validation. It adopts only
  a clean worktree whose HEAD is one merge commit with two parents. The first
  parent is the blocked `local_head`; the second is already on
  `refs/remotes/origin/<worktree.yml base_branch>` (older pointers fall back
  to `GitOps#origin_default_branch`) and not already an ancestor of the
  blocked head. The grant must refuse at HEAD and validate with the blocked
  head substituted (unless a matching `retirement.json` already exists from an
  interrupted retirement).
- Adoption retires the generation with `PassArchive.retire!`. Grants expire
  with `expiry_reason=base_merge_adopted`, and passes and receipts move to
  `reviews/archive/<utc>-base-merge-<oid12>/` with a deterministic
  `retirement.json`. The marker then clears, and one fresh review of the
  merged head runs from pass 1 through the normal CI gates. The grant is not
  carried and no budget is refunded. Replays reuse the same archive.
- Unrelated head changes keep `review_grant_evidence_changed`. These include
  non-merge commits, extra commits around the merge, merges of non-base
  branches, octopus merges, and edited grant evidence. A dirty worktree
  blocks as `review_base_merge_refused` (`dirty_worktree`). Ungranted tasks
  and spent grants keep the existing retry path.
- Tests: `test/unit/review_base_merge_adoption_test.rb`,
  `test/integration/review_grant_test.rb`
  (`test_base_merge_after_a_granted_base_conflict_restarts_one_fresh_review`);
  shared helpers live in `test/support/review_grant_fixture.rb`.
- Pages: [[publication-recovery]], [[commands/review-grant]],
  [[stages/review]], [[gaps]].
