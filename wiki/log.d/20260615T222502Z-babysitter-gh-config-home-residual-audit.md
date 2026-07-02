## [2026-06-15T22:25:02Z] wiki - audit residual babysitter gh config-home docs

**Action:** Audited residual wiki commit `6a6cf990`, which committed the previous babysitter dry-run documentation refresh for source commit `f12c46c7`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent compiled [[log]] entries, and the latest 2026-06-15 babysitter log fragments first; `qmd search "babysitter gh config home dry run trusted gh config dir"` surfaced the current babysitter command/module/testing/gap coverage, and the configured master wiki path had no matching project-specific context. Inspected the residual diff plus current `bin/hive-babysitter-stub-gh`, `bin/hive-babysitter-stub-git`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Refresh:** Confirmed the committed `gh` config-home coverage matches the code: the dry-run wrapper captures the parent GitHub config directory before command-local env can alter it, and the shared `gh` stub re-exposes only that trusted path while setting `HOME` to `File::NULL`. While auditing the same touched pages, corrected stale git dry-run env-seam prose in [[commands/babysit]] and [[modules/babysitter]] so it includes the current `GIT_EXEC_PATH`, `GIT_ASKPASS`, and `SSH_ASKPASS` guards already present in source, tests, and [[gaps]]. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. The uncertainty remains unchanged: no checked-in artifact proves a full live `hive babysit --once PROJECT --dry-run` agent run after the latest dry-run stub/env hardening. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[gaps]]
