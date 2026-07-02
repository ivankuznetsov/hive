## [2026-06-16T04:03:26Z] babysitter - block dry-run gh hostname overrides

**Action:** Hardened `bin/hive-babysitter-stub-gh` so the dry-run `gh` stub strips only known-safe leading repo selectors before allowlist classification. Other leading globals now fail closed, including `--hostname <host>` and `--hostname=<host>`, so an otherwise read-only `gh api` or `gh auth status` call cannot redirect authenticated traffic to an agent-chosen host.

**Coverage:** Added `test_gh_stub_skips_leading_hostname_overrides` to `test/unit/babysitter/dry_run_env_test.rb`, proving both separate and glued hostname forms are skipped, logged, and do not reach the fake real `gh` binary.

**Verified:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`

**Links:** [[modules/babysitter]], [[testing]]
