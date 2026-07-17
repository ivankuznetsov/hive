## [2026-07-17T19:58:50Z] testing - preserve eval reports until replacement is ready

**Action:** Fixed Hive patrol finding `command-bin-hive-1` by superseding the
unsafe `bin/hive-eval` stale-report cleanup contract. Parsing, positional, and
scenario-validation failures no longer unlink caller-selected paths. A valid
run writes to a same-directory temporary file, verifies the staged JSON uses
the `hive-eval-report` schema, and atomically renames it over the selected
report; if the runner produces no report, pre-existing bytes remain unchanged.

**Tests:** Updated `test/eval/support/reporter_test.rb` to preserve existing
Hive and non-Hive content across usage/scenario failures and added coverage for
a valid runner invocation that produces no report. Verified the focused
preservation regressions, the complete reporter test, and targeted RuboCop.

**Links:** [[testing]], [[gaps]]
