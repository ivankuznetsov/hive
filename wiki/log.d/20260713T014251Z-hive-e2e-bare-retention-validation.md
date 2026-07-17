## [2026-07-13T01:42:51Z] bug - hive-e2e rejects bare cleanup retention flags

**Action:** Added pre-dispatch validation for separate-form `--retain-days` and `--retain-failed-days` options in `bin/hive-e2e`. Thor retains an optional string option's configured default when the flag is terminal or followed by another switch; malformed `clean` calls could therefore reach destructive cleanup with the default window. Bare or option-followed retention flags now raise the existing usage error before Thor dispatch, while explicit negative values still reach the retention-window validator.

**Tests:** Added a six-case binary regression covering both retention flags as the final token and immediately before `--json` or `--dry-run`. Every case must exit `64`, use the expected JSON or human error surface, and preserve an eligible old run directory. Verified the full `test/e2e/lib/hive_e2e_binary_test.rb` suite (38 tests, 305 assertions).
