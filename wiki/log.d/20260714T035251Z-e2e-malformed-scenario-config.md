## [2026-07-14T03:52:51Z] e2e - classify malformed scenarios as config failures

**Action:** Fixed `bin/hive-e2e run` and `list` so malformed scenario YAML or
definitions emit the existing `preflight` error contract and exit `78` instead
of being reported as generic harness/test failures with exit `1`. Added focused
executable regressions for both commands in JSON and human modes, and refreshed
[[e2e]] / [[testing]] contract wording.

**Verified:** `bundle exec ruby -Itest test/e2e/lib/hive_e2e_binary_test.rb`;
`bundle exec rake e2e:lib_test`; `bundle exec rake test`;
`bundle exec rubocop bin/hive-e2e test/e2e/lib/hive_e2e_binary_test.rb`.
