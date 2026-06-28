# babysitter skip-log hard-link guard

**Action:** Hardened `bin/hive-babysitter-stub-git` and
`bin/hive-babysitter-stub-gh` so an existing dry-run skip log must have link
count exactly 1 before open and the opened file descriptor must still have link
count exactly 1 before the audit line is written. This closes the same-user
hard-link path where a skipped `git` / `gh` command could append its dry-run
audit line to another file outside the worktree.

**Coverage:** Added `test_stubs_refuse_hardlinked_skip_log` to
`test/unit/babysitter/dry_run_env_test.rb`; it hard-links the configured skip
log to an outside file, runs skipped `git` and `gh` commands, and asserts the
outside file is unchanged while both stubs warn and continue skipping.

**Verification:** `bundle exec ruby -Itest
test/unit/babysitter/dry_run_env_test.rb -n
test_stubs_refuse_hardlinked_skip_log`; `env -u GIT_EXEC_PATH bundle exec ruby
-Itest test/unit/babysitter/dry_run_env_test.rb`; `ruby -c
bin/hive-babysitter-stub-git && ruby -c bin/hive-babysitter-stub-gh`; `bundle
exec rubocop bin/hive-babysitter-stub-git bin/hive-babysitter-stub-gh
test/unit/babysitter/dry_run_env_test.rb`; `git diff --check`.

**Links:** [[modules/babysitter]], [[testing]]
