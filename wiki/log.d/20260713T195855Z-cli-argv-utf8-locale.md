## [2026-07-13T19:58:55Z] cli - make argv UTF-8 validation locale-independent

**Action:** Updated the pre-dispatch argv guards in `bin/hive` and
`bin/hive-e2e` to validate a duplicated UTF-8 view of each argument. Raw invalid
bytes are now rejected under `LC_ALL=C` instead of being accepted as valid
`ASCII-8BIT` and reaching command dispatch.

**Verified:** Added `LC_ALL=C` raw-byte regressions for both binaries and ran
`bundle exec ruby -Itest -Ilib test/integration/cli_usage_error_json_test.rb`,
`bundle exec ruby -Itest -Ilib test/e2e/lib/hive_e2e_binary_test.rb`, and
`bundle exec rubocop bin/hive bin/hive-e2e test/integration/cli_usage_error_json_test.rb test/e2e/lib/hive_e2e_binary_test.rb`.
