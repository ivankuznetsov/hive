## [2026-07-08T01:32:44Z] testing - hive-eval preserves non-report files on usage errors

**Action:** Hardened `bin/hive-eval` report cleanup so usage-error paths remove the default report or an existing selected JSON document only when it is a `hive-eval-report`. Normal eval runs still clear the selected report path after argv and scenario validation succeeds, but malformed invocations no longer unlink arbitrary caller files passed through `--report`.

**Tests:** Added `test_cli_usage_errors_preserve_existing_non_report_files` in `test/eval/support/reporter_test.rb`, covering parser rescue, stray positional arguments, and missing scenarios. Verified with `bundle exec ruby -Itest -Itest/eval test/eval/support/reporter_test.rb` and `bundle exec rubocop bin/hive-eval test/eval/support/reporter_test.rb`.
