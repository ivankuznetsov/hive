---
date: 2026-06-18
slug: review-coverage-gate-fix
pages: [testing]
---

Fixed the PR #512 Ruby CI red caused by the 100% line-coverage gate, not by
test assertions. The failing GitHub job had 5,436 passing runs but reported two
uncovered lines: `lib/hive/stages/review.rb:392` (the caller path that converts
`:wall_clock_exceeded` from `run_triage_with_retries` into
`REVIEW_STALE reason=wall_clock`) and `lib/hive/daemon/dispatcher.rb:710` (the
dry-run digest pseudo-child rescue that logs `digest_scheduler.complete` write
failures as `:fatal`).

Added focused regressions in `test/integration/run_review_test.rb` and
`test/unit/daemon/dispatcher_test.rb` for those branches. Updated [[testing]]
to name the new coverage contracts. Page count stayed 80, so [[index]] did not
need a catalog update. Did not edit compiled [[log]] and did not run `qmd update`
or `qmd embed`.
