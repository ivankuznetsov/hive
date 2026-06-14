## [2026-06-12T18:34:21Z] wiki — audit babysitter gh api cache dry-run coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `2c30a5d1` changed `bin/hive-babysitter-stub-gh` and `test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter dry-run gh api cache"` returned the existing babysitter module/gap/log coverage, and the configured master wiki path had no relevant cross-project pattern beyond unrelated cache references. Inspected the committed diff plus current `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Documented that the dry-run `gh` stub skips `gh api --cache` and `gh api --cache=<ttl>` even when the method is explicitly GET, because the GitHub CLI writes a local API cache under the caller's cache home. Refreshed command/module/test/gap coverage for the new focused regression that uses a fake gh binary writing under `XDG_CACHE_HOME` and verifies the cache directory is not created. Page coverage stayed within existing babysitter pages, so [[index]] did not need a catalog edit. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]
