## [2026-06-07T16:15:26Z] hive-eval usage errors

**Action:** Hardened `bin/hive-eval` CLI parsing so `OptionParser` failures and unexpected positional arguments print concise `hive-eval:` usage errors and exit 64 before scenario lookup, report setup, or eval-suite execution. Added focused subprocess regressions in `test/eval/support/reporter_test.rb` for invalid options, missing `--scenario` / `--report` values, and stray positional arguments, and refreshed [[testing]] with the usage-error contract.

**Refreshed pages:**
- [[testing]]
