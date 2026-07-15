# babysitter skip-log open-race hardening

**Action:** Fixed patrol finding `command-bin-hive-babysitter-skip-log-rb-1`: the skip-log preflight discarded the `File.lstat` identity, and missing targets were created without exclusivity, so a concurrent pathname swap could substitute another current-user file before the descriptor checks.

**Result:** Existing logs now require the opened descriptor's device/inode to match the preflighted file. Missing logs use `File::CREAT | File::EXCL`; creation and replacement races are rejected and warned rather than retried. The existing no-follow, nonblocking, regular-file, owner, and link-count checks remain in place.

**Coverage:** `test/unit/babysitter/dry_run_env_test.rb` deterministically swaps an existing path at the `File.open` seam and races a missing-path creation with a hard link, verifying both attempts are rejected without modifying the substituted target. Refreshed [[commands/babysit]], [[modules/babysitter]], and [[testing]].
