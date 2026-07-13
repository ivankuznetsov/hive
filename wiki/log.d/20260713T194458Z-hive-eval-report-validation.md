## [2026-07-13T19:44:58Z] testing - require validated hive-eval reports on success

**Action:** Fixed patrol finding `command-bin-hive-1` by making `bin/hive-eval`
fail closed after a zero child exit unless the selected report is a newly
created regular file containing parseable `hive-eval-report` v1 JSON with
passing entries covering exactly the requested scenario files. This prevents a
child that skips the reporter from producing a false-green eval result.

**Tests:** Added missing-report, invalid-JSON/schema, and scenario-coverage
regressions to `test/eval/support/reporter_test.rb`; verified the full reporter
suite and targeted RuboCop checks.
