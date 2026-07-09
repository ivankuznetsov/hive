## [2026-07-06T09:38:55Z] babysitter - skip git help viewer dispatch in dry-run

**Action:** Hardened `bin/hive-babysitter-stub-git` so allowlisted read commands now skip help/manual dispatch options before passthrough. `git <command> --help` routes through `git help` and can execute repo/user configured manual, web, or info viewers, so the stub now treats `--help`, `--man`, `--web`, `--html`, and `--info` as unsafe command options.

**Coverage:** Added a real-git regression in `test/unit/babysitter/dry_run_env_test.rb` that configures a repo-local `man.viewer` helper, invokes `git status --help` through the dry-run stub, and asserts the command is skipped, logged, and the helper marker is not created. Verified with `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`.
