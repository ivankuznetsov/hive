## 2026-11-08 — Review CI gate blocks base conflicts; backward approve archives review passes

- `Review::RemoteCi` treats PR mergeability as part of hosted settlement.
  `mergeable=CONFLICTING` on the exact head returns `REVIEW_CI_STALE
  gate=github reason=base_conflict` on first observation, with no CI-fix
  agent; `reviews/ci-blocked.md` names the base and the recovery (merge
  `origin/<base>` with a merge commit, no rebase/force-push, then
  `workflow.retry`). `UNKNOWN`/missing mergeability keeps polling within
  `timeout_sec.review_ci`; still unresolved at the bound with settled checks
  fails closed as `REVIEW_ERROR phase=ci gate=github
  reason=mergeability_unknown`. `BEHIND` is informational only. Disabled hosted
  checks are unchanged. `Hive::Gh.pr_status_rollup` also reads `baseRefName`.
  `RemoteCi::Result` gained an optional `reason`; `hive run` next-action text
  for `reason=base_conflict` names the base merge.
- Backward `hive approve` whose rewind interval includes the review stage
  moves top-level numbered `reviews/*-NN.md` files into
  `reviews/archive/<utc>-<from>-to-<to>/` (`Hive::Stages::Review::PassArchive`),
  keeping `ci-blocked.md`, `deferred-findings.md`, `suppressed.md`. Rollback
  renames them back. This replaces the failure where `--to 6-review` from
  8-finalize left pass 06 files and the next review hit `REVIEW_ERROR
  reason=config_error` ("review pass NN=6 exceeds review.max_passes=3").
  Archiving (rather than generation-scoped pass counting) follows the existing
  outcome-evidence rework precedent (`reviews/archive/rework-NN/`) and keeps
  the top-level files the single current-generation source for every reader.
- Tests: `test/unit/stages/review/{remote_ci,ci_gates,pass_archive}_test.rb`,
  `test/unit/commands/{approve,run}_test.rb`,
  `test/integration/run_approve_test.rb`.
- Hive task: review-and-finalize-do-not-261108-6f72.
