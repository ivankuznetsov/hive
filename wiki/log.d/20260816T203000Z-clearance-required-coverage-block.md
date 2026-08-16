## 2026-08-16 — Restore clearance coverage for required-coverage blocking

**Problem:** Dropping the `level == "mandatory"` promotion of optional rows in
`lib/hive/plan_review/coverage_evaluator.rb` made optional failures degrade
instead of block. The one clearance test that reached the blocking arm used an
optional `security` row, so rewriting it as the degraded case left
`lib/hive/plan_review/clearance.rb` line 50 — the `coverage_result.blocked?`
return — with no caller. The merged exact-coverage gate rejected the file at
97.50%, and `rake test (Ruby 3.4)` failed with it.

**Fix:** Added
`test_required_failed_coverage_stops_clearance_with_a_waiver_action` to
`test/unit/plan_review/clearance_test.rb`, asserting that a *required* failed
coverage row still yields `blocked` with the named coverage blocker and the
waiver action. The degraded case keeps its own test, so both arms of the
required/optional split are pinned at the clearance layer rather than only in
`coverage_evaluator_test.rb`.

**Verification:** `ruby -Itest -Ilib test/unit/plan_review/clearance_test.rb`
passes (7 runs), and a scoped coverage run leaves line 50 covered. See
[[testing]].
