## [2026-11-26T18:10:00Z] e2e - scope unexpected run failure diagnostics

**Action:** Updated `bin/hive-e2e` and `test/e2e/lib/runner.rb` so unexpected
`StandardError` failures caught by `bin/hive-e2e run` report the canonical
`<ExceptionClass>: <original message>` diagnostic in both human stderr output
and the unchanged `hive-e2e-error.v1` JSON envelope (`error_kind: "run_failed"`,
`command: "run"`, exit `1`). Opt-in `HIVE_E2E_DEBUG=1` appends one stderr-only
diagnostic block containing only the rescued exception's own class, message,
and backtrace (guarding `nil` backtraces via `Array(error.backtrace)` and never
walking `Exception#cause`). Expected errors, ordinary scenario failures, and
outer rescue contracts remain unchanged.

`Runner#run_all` still attempts its best-effort `status: "crashed"` report
write before re-raising an unexpected run failure, but now swallows secondary
`StandardError`s from the write so the original exception identity, backtrace,
and cause reach callers intact. Updated [[e2e]] with the scoped diagnostic and
crashed-report contracts and recorded the pre-existing post-report-emission
ordering and binary-fixture concurrency limits in [[gaps]].

**Verification:** `bin/test test/e2e/lib/hive_e2e_binary_test.rb
test/e2e/lib/runner_test.rb` passed (89 runs, 1,741 assertions, 0 failures, 0
errors, 0 skips), covering human/JSON parity, exact `HIVE_E2E_DEBUG=1`
activation, outermost-only backtraces with non-nil causes and repeated frames,
`backtrace == nil` in debug mode, expected-error and outer-rescue compatibility,
repeated blocked runs, and crashed-report preservation across four writer error
classes. `bundle exec rubocop bin/hive-e2e test/e2e/lib/runner.rb
test/e2e/lib/runner_test.rb test/e2e/lib/hive_e2e_binary_test.rb` passed with
no offenses.
