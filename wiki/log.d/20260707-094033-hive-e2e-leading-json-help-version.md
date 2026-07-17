## [2026-07-07T09:40:33Z] e2e — leading JSON top-level help/version

**Action:** Fixed `bin/hive-e2e` wrapper normalization so recognized leading JSON boolean flags are stripped before top-level `--help` / `-h` / `--version` / `-v`; those invocations now print usage or the version instead of falling into default scenario selection with `no_scenarios`. Added focused `test/e2e/lib/hive_e2e_binary_test.rb` coverage for `--json --help`, `--json -h`, `--json --version`, and `--json -v`.

**Refreshed pages:**
- [[e2e]]
- [[testing]]
