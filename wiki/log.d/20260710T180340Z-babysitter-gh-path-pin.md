## [2026-07-10T18:03:40Z] babysitter — pin PATH before gh passthrough

**Action:** Fixed patrol finding `command-bin-hive-e2e-3` by pinning `PATH=/usr/bin:/bin` before `bin/hive-babysitter-stub-gh` execs an allowlisted real `gh` read. Real `gh` can invoke Git for repository discovery; preserving the agent-controlled PATH let that child lookup run a fake `git` ahead of the dry-run overlay and bypass the Git stub.

**Coverage:** Added `test_gh_stub_pins_path_before_real_gh_repository_discovery` to `test/unit/babysitter/dry_run_env_test.rb`. Its fake real `gh` runs a repository-discovery Git command while a marker-writing fake `git` leads the caller PATH, and asserts the fake helper is not invoked.

**Verified:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`

**Links:** [[commands/babysit]], [[modules/babysitter]], [[testing]]
