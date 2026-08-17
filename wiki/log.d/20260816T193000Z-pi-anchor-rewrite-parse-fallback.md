## 2026-08-16 — Cover the Pi anchor-rewrite parse fallback

**Problem:** `normalize_host_anchors` in
`lib/hive/plan_review/adapters/ce_doc_review.rb` rescues `JSON::ParserError` and
returns the reviewer bytes untouched, deliberately deferring the diagnostic to
the shared result parser rather than inventing a second one. No test reached
that rescue, so the merged exact-coverage gate rejected the file at 99.47% line
coverage with line 338 uncovered — and `rake test (Ruby 3.4)`, which aggregates
the coverage result, failed with it.

**Fix:** Added
`test_pi_anchor_rewrite_defers_unparsable_output_to_the_result_parser` to
`test/unit/plan_review/ce_doc_review_adapter_test.rb`: a Pi-routed request whose
runner publishes non-JSON output. The adapter returns `terminal_failure` with
the canonical `not valid JSON` diagnostic from
`Hive::PlanReview::ResultParser`, pinning the deferral rather than just the
line.

**Verification:** `ruby -Itest -Ilib
test/unit/plan_review/ce_doc_review_adapter_test.rb` passes (22 runs), rubocop
reports no offenses, and a scoped coverage run leaves line 338 covered. See
[[testing]].
