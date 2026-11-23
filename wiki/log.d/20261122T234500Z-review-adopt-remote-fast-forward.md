## 2026-11-22 — Review adopts a PR branch fast-forwarded outside Hive

- `ReviewPublicationRecovery.classify` distinguishes `behind`: the local head
  is a strict ancestor of the PR head. `divergent` now means only true
  divergence. Before, an operator push onto a published review branch was
  recorded as `divergent`/`remote_conflict`. In the hivedev F4 task it then
  wedged `workflow.retry` on the suspended review grant
  (`review_grant_evidence_changed`).
- `Review::Publication` stops on `behind` with
  `publication_reason=remote_fast_forward_adoptable`. It never pushes or
  adopts mid-run.
- `RecoveryCoordinator#resume` adopts before grant validation, under the
  task lock, through `Hive::ReviewFastForwardAdoption`. It handles
  `review_publication_failed` markers whose reason is
  `remote_fast_forward_adoptable` or legacy `remote_conflict`.
- Adoption re-observes the PR branch and requires a clean worktree and a
  locally present strict descendant. It first retires the review generation
  with `PassArchive.retire!`: grants expire with
  `expiry_reason=remote_fast_forward_adopted`, and passes and receipts move to
  `reviews/archive/<utc>-remote-fast-forward-<oid12>/` with a
  `retirement.json`. It then merges through the new `AgentGitGate.fast_forward`
  (`merge --ff-only --no-overwrite-ignore` at the exact OID after a fresh
  re-observation). The next run starts at pass 1 on the adopted head.
- A legacy `remote_conflict` marker falls back to the old retry path whenever
  the fast-forward cannot be established.
- Non-fast-forwards keep their old outcome. Unsafe fast-forwards block as
  `remote_fast_forward_refused` with the exact operator action.
- Outcome-evidence rework now archives through the same `PassArchive.retire!`.
- `TaskClosure` retained-fix details label a PR reference ahead of the worktree
  `behind`/`published`. Closure still requires the operator decision.
- Pages: [[publication-recovery]], [[modules/agent_git_gate]],
  [[modules/markers]], [[commands/review-grant]], [[stages/review]], [[gaps]].
