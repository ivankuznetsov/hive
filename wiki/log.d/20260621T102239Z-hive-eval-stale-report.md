## [2026-06-21T10:22:39Z] testing - hive-eval clears stale reports on usage errors

**Action:** Updated [[testing]] after fixing `bin/hive-eval` report lifecycle handling. Usage-error exits now remove the selected report path before returning `64`, including validation failures after `--report` has been parsed, so downstream readers cannot mistake a previous `hive-eval-report` JSON document for the failed invocation's output.

**Tests:** Added `test_cli_usage_error_removes_existing_selected_report` in `test/eval/support/reporter_test.rb` and verified `bundle exec ruby -Itest test/eval/support/reporter_test.rb`.
