## [2026-07-10T09:48:17Z] hive-eval - require executed scenario reports

**Action:** Fixed patrol finding `command-bin-hive-e2e-1`. `bin/hive-eval`
now rejects inherited Rake dry-run options (including bundled, abbreviated,
underscored, and shell-quoted forms), clears `RAKEOPT` before launching the
child, and treats a zero child exit as success only after validating complete,
passing scenario records in a version-1 `hive-eval-report`. Filtered runs also
require the requested scenario file. Each invocation writes to a private report
path and atomically publishes only its own validated output, so concurrent runs
cannot validate each other's report.

**Coverage:** Added subprocess regressions for Rake dry-run spellings, child
`RAKEOPT` scrubbing, a child that exits zero without writing its private report,
malformed/wrong-schema/empty/semantically incomplete reports, failed entries on
a zero child exit, filtered reports that omit the requested scenario, and
overlapping invocations sharing one requested path.

Private report directories require a non-writable or sticky parent. Cleanup
failures warn without overriding the child/result exit status.

**Verified:** `bundle exec ruby -Itest test/eval/support/reporter_test.rb` and
`bundle exec rubocop bin/hive-eval test/eval/support/reporter_test.rb`

**Links:** [[testing]], [[gaps]]
