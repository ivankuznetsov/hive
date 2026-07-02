## [2026-06-18T17:30:21Z] babysitter - refresh FIFO skip-log executable-stub coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after
commit `3e461d76` changed `bin/hive-babysitter-stub-git`,
`bin/hive-babysitter-stub-gh`, and
`test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent [[log]] entries first. `qmd search "command API surface routes
handlers commands executable entrypoints README"` surfaced prior wrapper and
babysitter refresh patterns; the configured master wiki had only generic
route/API coverage guidance.

Inspected the committed diff plus the current dry-run stubs and focused unit
tests. Documented that skipped-command audit logging now preflights an existing
log path with `File.lstat`, rejects non-regular or non-current-uid targets
before open, uses `File::NOFOLLOW | File::NONBLOCK`, creates missing logs as
mode `0600`, and re-checks the opened file. This keeps dry-run default-deny
when the audit sink is unsafe and prevents a FIFO `HIVE_BABYSITTER_DRY_RUN_LOG`
override from hanging the stub while waiting for a reader.

The focused test suite now covers both `git` and `gh` stubs against a FIFO log
path through a timeout-bounded capture helper. No new wiki page was needed, so
[[index]] did not need a catalog update. The live uncertainty remains recorded
in [[gaps]]: no checked-in artifact proves a full
`hive babysit --once PROJECT --dry-run` live-agent run after these stub changes.
Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]
