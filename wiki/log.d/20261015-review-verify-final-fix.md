# 2026-10-15 — Review verifies the final pass's fixes before completing

- `Stages::Review.run!` used to `break` to Phase 5 right after a successful
  fix on the last allowed pass (`pass >= review.max_passes`). With the default
  cap of 2, pass-2 fixes were never reviewed, never CI-gated, and not pushed
  until finalize; the all-clean branch that holds the exact-head CI gate and
  the `errors-NN.md` partial-reviewer-failure guard was skipped entirely.
  Real PRs finalized with unreviewed pass-2 commits, one with failing CI.
- `review.max_passes` now means "max_passes fix passes, plus one verify-only
  pass when the last one applied fixes". A pass above the configured cap runs
  reviewers and triage but never Phase 4: clean → exact-head CI gates (push)
  → Phase 5; any finding or escalation → `REVIEW_STALE
  reason=final_fix_unverified accepted=N escalations=M pass=NN`. A reviewer
  failure on a clean verify pass still lands `reviewer_partial_failure`.
- Every route into Phase 5 now crosses `completion_ci_gate`, including the
  final-pass fix-guardrail approval, which previously skipped CI on the
  approved HEAD. A CI fixer commit there opens a verify-only pass.
- `fix-success-NN.md` records `kind=clean|fixed|ci_repaired|approved`. A
  restart after a final-pass fix (`fixed`/`ci_repaired` bound to HEAD, or a
  legacy sentinel whose pass had accepted `[x]` findings) resumes into the
  verify pass instead of Phase 5. Retrying a `final_fix_unverified` STALE
  re-runs the verify pass's reviewers rather than the fix agent.
- `test_max_passes_cap_completes_after_final_allowed_fix`, which pinned the
  old behaviour, is replaced by the verify-pass tests in
  `test/integration/run_review_test.rb`.
- Follow-up: the on-disk pass guard (`max_review_pass`) accepted only
  `max_passes + 1`, so retrying a pass admitted by a CI repair during the
  verify pass (`max_passes + 2`) failed with `REVIEW_ERROR
  reason=config_error`. The ceiling now comes from
  `Review.admitted_pass_ceiling`, which extends `max_passes + 1` by one for
  each consecutive `kind=ci_repaired` receipt; a pass with no admitting
  receipt is still rejected.
