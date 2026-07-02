## [2026-06-16T04:23:15Z] wiki - audit residual babysitter gh-hostname wiki commit

**Action:** Refreshed LLM wiki coverage after commit `ede81ac7` committed residual wiki changes for the babysitter gh-hostname dry-run audit. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter gh hostname dry-run audit"` returned the current babysitter module page, and the configured master wiki path had no additional Hive-specific guidance. Inspected the committed diff plus the source commit `a86ca033`, current `bin/hive-babysitter-stub-gh`, `bin/hive-babysitter-stub-git`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Confirmed the documented `gh --hostname` boundary matches source: only repo selectors are stripped before classification, leading hostname overrides fail closed and are logged/skipped, and subcommand-local non-token `gh auth status -h github.com` remains allowed. Added source-synced notes for the git dry-run env seams that were still under-described in command/module docs (`GIT_EXEC_PATH`, `GIT_ASKPASS`, `SSH_ASKPASS`) and carried forward the existing uncertainty that no checked-in live-agent dry-run smoke artifact exists after the gh-hostname hardening. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[gaps]]
