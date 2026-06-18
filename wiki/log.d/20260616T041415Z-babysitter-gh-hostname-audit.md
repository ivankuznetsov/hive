## [2026-06-16T04:14:15Z] wiki - audit babysitter gh hostname dry-run coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `a86ca033` changed `bin/hive-babysitter-stub-gh`, `test/unit/babysitter/dry_run_env_test.rb`, [[modules/babysitter]], [[testing]], and a prior implementation log fragment. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "dry-run gh arbitrary host patrol host allowlist"` surfaced existing patrol/babysitter dry-run history, and direct wiki/source search found the current module/testing coverage. Inspected the committed diff plus the current gh stub, focused dry-run tests, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

Confirmed the executable boundary: dry-run `gh` now strips only repo selectors (`-R`, `--repo`, `--repo=...`) before read-only classification. Leading `--hostname <host>` and `--hostname=<host>` remain in argv, fail the allowlist, are logged as skipped, and do not exec the real `gh`, while subcommand-local non-token `gh auth status -h github.com` remains an allowed read. Updated [[commands/babysit]] and [[gaps]] to name that boundary and the remaining uncertainty. Page coverage stayed within existing command/module/testing/gap pages, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]
