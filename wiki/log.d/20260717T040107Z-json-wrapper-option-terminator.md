## [2026-07-17T04:01:07Z] wiki — bound JSON wrapper mode to parsed options

**Action:** Updated the `bin/hive` and `bin/hive-e2e` wrapper contracts after
their error-mode scanners were changed to stop at the first `--` option
terminator. Wrapper-owned errors still honor the last recognized JSON boolean
in the option-parsed region, but JSON-looking positional literals after the
terminator no longer enable or disable structured output. Added focused
entrypoint regressions for both a literal `--json` and a literal `--no-json`
after `--`; [[testing]] records the expanded executable contract. The existing
pages were sufficient, so [[index]] did not need a catalog update. Did not edit
the compiled [[log]] or run `qmd update`/`qmd embed`.

**Tests:**
- `bundle exec ruby -Itest test/integration/cli_version_test.rb -n /option_terminator/`
- `bundle exec ruby -Itest test/e2e/lib/hive_e2e_binary_test.rb -n /option_terminator/`

**Refreshed pages:**
- [[cli]]
- [[commands]]
- [[e2e]]
- [[testing]]
