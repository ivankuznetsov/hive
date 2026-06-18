## [2026-06-18T17:49:45Z] wiki - audit gh dry-run host-selector coverage

**Action:** Audited commit `44768970` after it touched `bin/hive-babysitter-stub-gh`, dry-run tests, and babysitter wiki coverage. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter gh host selector dry-run audit"` surfaced existing babysitter/gaps context, and the configured master wiki path had no matching context. Verified the committed diff plus current `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, and `test/unit/babysitter/dry_run_env_test.rb`.

**Coverage:** Confirmed [[commands/babysit]], [[modules/babysitter]], and [[testing]] describe the new `gh` dry-run host-selector boundary: `--hostname`, host-qualified `-R` / `--repo`, host-qualified repo/PR operands, full URL `api` operands, `auth status` `-h` forms, and host/config environment scrubbing. Refreshed [[testing]] metadata and consolidated [[gaps]] so the older 2026-06-15 dry-run-stub live-smoke gap no longer duplicates the current 2026-06-18 uncertainty. Page coverage did not change, so [[index]] did not need a catalog update.

**Verified:** `git diff --check -- wiki/gaps.md wiki/testing.md wiki/log.d/20260618T174945Z-babysitter-gh-host-selector-audit.md`; `bundle exec ruby -Itest test/unit/wiki_log_test.rb`; `env -u GIT_EXEC_PATH bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb`. Did not run `qmd update` or `qmd embed`.

**Links:** [[commands/babysit]], [[modules/babysitter]], [[testing]], [[gaps]]
