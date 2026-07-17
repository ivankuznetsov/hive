## [2026-07-03T09:26:47Z] testing - hive-eval report cleanup is schema-gated

**Action:** Fixed the `bin/hive-eval` report cleanup boundary so usage errors and pre-run cleanup only remove existing files that parse as `hive-eval-report` JSON documents. Non-report files supplied via `--report` now survive parse errors and missing-scenario validation failures, while stale eval reports are still cleared before callers can read old JSON.

**Tests:** Added `test_cli_invalid_invocations_preserve_non_report_files_passed_as_report` in `test/eval/support/reporter_test.rb`; verified it failed before the runner change and passed after. Also ran `bundle exec ruby -Itest -Itest/eval test/eval/support/reporter_test.rb`.
