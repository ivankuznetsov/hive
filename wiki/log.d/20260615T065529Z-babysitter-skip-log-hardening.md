# babysitter dry-run skip-log hardening refresh

Refreshed command/API and executable-entrypoint wiki coverage after commit
`f33ff951` changed `bin/hive-babysitter-stub-git`,
`bin/hive-babysitter-stub-gh`, and `test/unit/babysitter/dry_run_env_test.rb`.
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first; the
compiled log is stale relative to newer `wiki/log.d/` fragments, so recent
fragments were also checked without editing [[log]]. `qmd search "babysitter
dry-run skip log symlink realpath stub git gh"` surfaced prior babysitter
dry-run history, and the configured master wiki had no relevant project-specific
hit.

Inspected the committed diff plus the current dry-run git/gh stubs,
`test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]],
[[modules/babysitter]], [[testing]], and [[gaps]]. Resolved the generated wiki
conflict by keeping the current source-backed dry-run surface: exact read-only
`git branch` forms, `git remote show -n`, `gh auth status` token skips,
`gh api` file/cache skips, browser-launch skips, hermetic git passthrough, and
the new skip-log guard. The skip-log coverage records that skipped-command
audit logging now opens the configured skip log with `File::NOFOLLOW`, creates
new logs as mode `0600`, requires a regular file owned by the current uid, warns
without unskipping when the audit sink is unsafe or unavailable, and escapes
ASCII control characters in argv as `\xHH` before writing logs or stderr.
Recorded that this is unit-pinned by the symlinked skip-log and
control-character tests, while the full live
`hive babysit --once PROJECT --dry-run` agent smoke remains missing. No new wiki
page was needed, so [[index]] did not need a catalog update. Did not run
`qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]
