## [2026-07-15T04:47:16Z] babysitter — pin PATH before gh dry-run passthrough

**Action:** Fixed patrol finding `command-bin-hive-1` by setting `PATH=/usr/bin:/bin` before `bin/hive-babysitter-stub-gh` execs an allowlisted real `gh` read. Real gh invokes git for repository discovery; preserving the caller's PATH let an agent place a token-observing fake git before the dry-run overlay and execute it with `GH_TOKEN` still present.

**Coverage:** Strengthened the focused `gh pr view` passthrough regression in `test/unit/babysitter/dry_run_env_test.rb`: a fake real gh launches bare git while a marker-writing fake git leads the inherited PATH, and the test asserts the poisoned child never runs, the real gh still runs, Git trace env remains scrubbed, and no skip audit is emitted for the allowlisted read.

**Verified:** `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb` (39 runs, 1,548 assertions); `bundle exec rubocop bin/hive-babysitter-stub-gh test/unit/babysitter/dry_run_env_test.rb`; `ruby -c bin/hive-babysitter-stub-gh`.

**Links:** [[modules/babysitter]], [[commands/babysit]], [[testing]]
