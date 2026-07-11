## babysitter - scrub dynamic-loader environment before dry-run startup

**Action:** Fixed patrol finding `command-bin-hive-eval-1` by removing every
`LD_*` and `DYLD_*` variable for the duration of
`Hive::Babysitter::DryRunEnv.with_env`, restoring the caller's original values
on exit, and repeating the prefix scrub before both dry-run stubs exec an
allowlisted real binary.

**Coverage:** Added a Linux overlay regression that builds a marker-writing
preload library and proves neither `/bin/sh`, Ruby, nor the trusted `git`/`gh`
handoff loads it. Existing passthrough environment-recording tests now also pin
the defensive `LD_*`/`DYLD_*` scrub in both stubs.

**Verification:** `bundle exec ruby -Itest
test/unit/babysitter/dry_run_env_test.rb`; `bundle exec rubocop
lib/hive/babysitter/dry_run_env.rb bin/hive-babysitter-stub-git
bin/hive-babysitter-stub-gh test/unit/babysitter/dry_run_env_test.rb`.

**Links:** [[modules/babysitter]], [[testing]]
