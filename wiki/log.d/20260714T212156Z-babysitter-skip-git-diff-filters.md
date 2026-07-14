## [2026-07-14T21:21:56Z] babysitter - skip git diff conversion filters in dry-run

**Action:** Fixed patrol finding `command-bin-hive-babysitter-skip-log-rb-3` by removing `git diff` from the dry-run stub's read-only allowlist. Git working-tree diff performs check-in conversion, so repository-local `.gitattributes` and `filter.<driver>.clean` / `filter.<driver>.process` config could execute commands despite the existing `--no-ext-diff --no-textconv` hardening. All diff forms now take the default-deny skip/log path.

**Coverage:** Added real-Git regressions for clean and process filters. Each test configures a marker-writing repository filter and verifies a dry-run diff is skipped without executing it.

**Verification:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`; `bundle exec rubocop bin/hive-babysitter-stub-git test/unit/babysitter/dry_run_env_test.rb`.

**Links:** [[commands/babysit]], [[modules/babysitter]], [[testing]], [[gaps]]
