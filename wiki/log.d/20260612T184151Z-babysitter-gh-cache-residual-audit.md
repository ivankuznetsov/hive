## [2026-06-12T18:41:51Z] wiki — audit residual babysitter gh cache coverage commit

**Action:** Audited residual wiki commit `db383620`, which committed the previous babysitter dry-run documentation refresh after source commit `2c30a5d1` changed `bin/hive-babysitter-stub-gh` and `test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter gh api cache dry-run stub"` returned the existing babysitter module/gap/log coverage, and the configured master wiki path only had unrelated cache references. Inspected the committed wiki diff, the source commit diff, and current `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Confirmed the current pages are source-synced: dry-run `gh api` skips `--cache` and `--cache=<ttl>` even for explicit GET requests because gh writes a local API cache, explicit GET reads without `--cache` still pass through, and the focused regression uses a fake gh binary plus `XDG_CACHE_HOME` to prove the cache directory is not created. The existing [[gaps]] entry still records the remaining uncertainty: no in-tree artifact shows a full live-agent `hive babysit --once PROJECT --dry-run` run after the dry-run stub hardening. Page coverage stayed within existing babysitter pages, so [[index]] did not need a catalog edit. Did not run `qmd update` or `qmd embed`.

**Verified:**
- `bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`

**Refreshed pages:**
- [[log]]
