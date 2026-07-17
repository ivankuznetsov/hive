## [2026-07-06T10:07:58Z] testing - hive-eval preserves custom reports on validation errors

**Action:** Fixed `bin/hive-eval` report cleanup ordering for Hive patrol finding `command-bin-hive-3`. Custom `--report` paths are no longer unlinked before stray positional arguments, scenario basename validation, or scenario existence checks have passed; parser-level cleanup is limited to the default `tmp/hive-eval-report.json`, and valid eval runs still clear the selected report immediately before invoking `rake test:eval`.

**Tests:** Updated `test/eval/support/reporter_test.rb` to preserve preexisting caller-provided report paths on parser and validation errors while keeping the default stale-report cleanup coverage. Verified `bundle exec ruby -Itest -Itest/eval test/eval/support/reporter_test.rb`.
