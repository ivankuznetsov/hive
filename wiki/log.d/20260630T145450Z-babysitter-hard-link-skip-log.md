# babysitter hard-link skip-log guard

**Action:** Hardened both dry-run command stubs so skipped-command audit logs
must have exactly one hard link before and after open. This preserves the
existing `File.lstat`/`File::NOFOLLOW`/`file.stat` race checks while preventing a
worktree from pre-creating `.babysitter-dry-run-skipped.log` as a same-owner hard
link to another file.

**Coverage:** Added `test_stubs_refuse_hard_linked_skip_log` to
`test/unit/babysitter/dry_run_env_test.rb`; it proves both `git` and `gh` stubs
warn and skip without appending through the hard link. Refreshed
[[modules/babysitter]], [[commands/babysit]], and [[testing]]. No new wiki page
was needed, so [[index]] did not need a catalog update.
