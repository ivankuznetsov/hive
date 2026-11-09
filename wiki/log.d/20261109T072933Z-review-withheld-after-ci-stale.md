## 2026-11-09 — Clean-pass CI-stale retry no longer withholds publication

- Symptom: a reviewer-clean pass 3 (all findings deferred, no Phase 4) hit a
  transient hosted-CI failure at its completion gate and parked as
  `REVIEW_CI_STALE pass=3`. The operator re-ran the job and cleared the marker.
  The retry then completed the browser phase but ended
  `REVIEW_ERROR reason=review_publication_withheld publication_reason=fix_guardrail_receipt_required`.
- Cause: the CI-stale stop left `escalations-03.md` without `fix-success-03.md`.
  `pass_completion_status` therefore classified pass 3 `:fix_incomplete`, and
  run entry withheld publication for a possible interrupted Phase 4. Nothing in
  the all-clean path cleared it.
- Change: `Stages::Review#prior_receipt_holds_head?` skips that entry withhold
  when HEAD still equals the previous pass's `fix-success-(N-1).md` `head=`.
  HEAD movement past the last receipt still withholds, and Phase 4 still sets
  its own withhold.
- Tests: `test/integration/run_review_test.rb` (clean CI-stale retry completes;
  unreceipted HEAD movement still withheld).
- Pages: [[stages/review]].
