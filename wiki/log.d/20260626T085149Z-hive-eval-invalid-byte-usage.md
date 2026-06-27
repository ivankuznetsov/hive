## [2026-06-26T08:51:49Z] testing - hive-eval treats invalid-byte options as usage errors

**Action:** Updated the [[testing]] eval-runner contract after hardening
`bin/hive-eval` against invalid UTF-8 option values. `OptionParser#parse!` can
raise `ArgumentError: invalid byte sequence in UTF-8` before the normal
`OptionParser::ParseError` rescue runs; the wrapper now routes that parser
failure through the same exit-64 usage cleanup and keeps the `--report=...`
cleanup scanner byte-safe.

**Tests:** Added `test_cli_invalid_byte_report_value_clears_selected_report`
in `test/eval/support/reporter_test.rb`; verified the focused regression fails
before the fix and passes after, then ran the full
`bundle exec ruby -Itest -Itest/eval test/eval/support/reporter_test.rb`.
