## [2026-07-10T09:32:34Z] babysitter - reject non-private existing skip logs

**Action:** Fixed Hive patrol finding `command-bin-hive-3` by extending the
shared dry-run skip-log helper's existing pre-open and post-open identity checks
to reject files with any group or world permission bits. The `0600` create mode
does not alter a pre-existing file, so accepting an existing `0644` or `0666`
log could disclose skipped argv and let another local user forge the audit
trail.

**Coverage:** Added a focused regression for both the `git` and `gh` stubs that
verifies existing `0644` and `0666` logs remain untouched and the skipped
command still exits successfully with a warning. Verified the full
`test/unit/babysitter/dry_run_env_test.rb` suite.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
