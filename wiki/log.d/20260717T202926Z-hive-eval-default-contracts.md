## [2026-07-17T20:29:26Z] testing - run fast hive-eval contracts in the default suite

**Action:** Added `test/integration/hive-eval_binary_test.rb` so the default
unit/integration/babysitter task exercises `bin/hive-eval` parser rejection,
environment isolation, and report lifecycle behavior through a fake `bundle`
seam. Full eval report and scenario tests remain under the opt-in eval suite.
Naming the focused test after `hive-eval` also associates it with patrol's
`command-bin-hive-eval` feature mapping.

**Tests:** Verified the focused file directly and through `bundle exec rake
test TEST=test/integration/hive-eval_binary_test.rb` (4 runs, 46 assertions),
ran RuboCop on the new integration test, and passed `bundle exec rake coverage`
(7,282 runs, 75,224 assertions, 0 failures). The shell-backed fake-bundle
fixture avoids starting a nested coverage-instrumented Ruby child.
