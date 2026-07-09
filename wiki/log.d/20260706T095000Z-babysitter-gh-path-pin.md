## [2026-07-06T09:50:00Z] babysitter - pin gh dry-run passthrough PATH

**Action:** Fixed patrol finding `command-bin-hive-2` by hardening `bin/hive-babysitter-stub-gh` before it execs a real allowlisted `gh` read. The stub already scrubbed gh config, host, proxy, TLS, and Git child-process environment; it now also pins `PATH=/usr/bin:/bin` so real `gh` cannot resolve child `git` helpers from caller-writable PATH entries during dry-run passthrough.

**Coverage:** Added `test_gh_stub_pins_path_before_allowlisted_pr_view_passthrough` to `test/unit/babysitter/dry_run_env_test.rb`. The regression prepends a fake `git` to PATH, runs the allowlisted `gh pr view --json number` path through a fake real `gh` that calls `git --version`, and asserts the fake `git` marker is not created while real `gh` still runs.

**Verified:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb -n '/test_gh_stub_pins_path_before_allowlisted_pr_view_passthrough/'`; `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`.

**Links:** [[modules/babysitter]], [[commands/babysit]], [[testing]]
