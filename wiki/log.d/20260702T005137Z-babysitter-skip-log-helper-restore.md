## [2026-07-02T00:51:37Z] babysitter - restore shared skip-log helper wiring

**Action:** Fixed Hive patrol finding `command-bin-hive-eval-1`
(maintainability/medium) by restoring the documented shared skip-log helper for
the dry-run `git` and `gh` babysitter stubs. The stubs now both
`require_relative "hive-babysitter-skip-log"`, call `log_skip("git", argv)` or
`log_skip("gh", argv)`, and keep the security-critical skip-log open and argv
escaping helpers in one file. `hive.gemspec` and its packaging test include the
shared helper so packaged stubs can load it.

**Verified:**
- `ruby -c bin/hive-babysitter-skip-log.rb && ruby -c bin/hive-babysitter-stub-git && ruby -c bin/hive-babysitter-stub-gh`
- `bundle exec ruby -Itest test/unit/gemspec_test.rb`
- `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`
- `bundle exec rubocop bin/hive-babysitter-skip-log.rb bin/hive-babysitter-stub-git bin/hive-babysitter-stub-gh hive.gemspec test/unit/gemspec_test.rb`

**Links:** [[modules/babysitter]]
