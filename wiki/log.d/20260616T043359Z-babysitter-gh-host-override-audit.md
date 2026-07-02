## [2026-06-16T04:33:59Z] wiki - audit babysitter gh host override hardening

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `5c38a526` expanded the babysitter dry-run `gh` host hardening, and after HEAD commit `b30484b4` added a residual gap note. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter gh host override dry-run wiki refresh"` surfaced existing Hive babysitter, gaps, testing, and log context, while the configured master wiki path had no matching Hive-specific guidance. Inspected `git show` for `HEAD`, `5c38a526`, and `a86ca033`, plus current `bin/hive-babysitter-stub-gh`, `bin/hive-babysitter-stub-git`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Confirmed the current docs mostly matched source: dry-run `gh` now skips host overrides anywhere in argv, not only leading globals; only bare `OWNER/REPO` repo selectors remain allowed; host-qualified `--repo`/`-R`, command-position `--hostname`, and `gh auth status` `-h` / `-h<host>` / `-ah` all skip and log. Tightened [[commands/babysit]] test coverage wording, updated [[gaps]] so the open live-smoke uncertainty names source commit `5c38a526` and the expanded host-selector cases, and left [[index]] unchanged because page coverage did not change. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[gaps]]
