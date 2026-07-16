## [2026-07-16T21:00:43Z] babysitter - preserve parent gh authentication for dry-run reads

**Action:** Fixed patrol finding `command-bin-hive-babysitter-stub-gh-6` by preserving the parent-pinned `HIVE_BABYSITTER_TRUSTED_GH_CONFIG_DIR` before the `gh` stub scrubs command-local config environment. Allowlisted reads now keep an isolated temporary `HOME` but restore the captured path as `GH_CONFIG_DIR`, so credentials stored by `gh auth login` remain available while command-local `HOME`, `GH_CONFIG_DIR`, `XDG_CONFIG_HOME`, and private-handoff overrides remain untrusted.

**Coverage:** Updated `test/unit/babysitter/dry_run_env_test.rb` to exercise the overlay launcher and shared stub with `hosts.yml` as the only authentication source, while asserting token env is absent and command-local config overrides do not reach real `gh`.

**Verified:** `ruby -Itest test/unit/babysitter/dry_run_env_test.rb` (39 runs, 1,549 assertions, 0 failures).
