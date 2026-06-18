## [2026-06-16T04:54:27Z] wiki - audit babysitter gh host env dry-run coverage

**Action:** Refreshed LLM wiki command/API and executable-entrypoint coverage after commit `5668015c` changed `bin/hive-babysitter-stub-gh`, `test/unit/babysitter/dry_run_env_test.rb`, and existing babysitter wiki pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first. `qmd search "babysitter gh host override dry-run env glued -R"` returned no hits, so direct `rg` searches across this wiki and the configured master wiki path were used; they found the existing babysitter/gaps/testing/log coverage and no Hive-specific master guidance. Inspected the committed diff plus current `bin/hive-babysitter-stub-gh`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]].

**Coverage:** Confirmed the existing command/module/testing pages already describe the current dry-run `gh` boundary: host overrides are rejected across argv, glued host-qualified `-R<value>` / `-R=<value>` selectors skip, safe glued bare `-Rowner/repo` remains allowed for read-only calls, and allowed `gh` passthrough scrubs `GH_HOST`, `GH_REPO`, `GH_ENTERPRISE_TOKEN`, and `GITHUB_ENTERPRISE_TOKEN`. Updated [[gaps]] so the latest uncertainty and open live-smoke gap name HEAD commit `5668015c` instead of only the preceding wiki/source commits. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Verified:** `env -u GIT_EXEC_PATH bundle exec ruby -Itest test/unit/babysitter/dry_run_env_test.rb` passed (17 runs, 1139 assertions). This shell exports `GIT_EXEC_PATH=/usr/lib/git-core`; the focused command intentionally unsets it because the git dry-run stub treats that env seam as unsafe before allowed git reads reach the fake binary.

**Refreshed pages:**
- [[gaps]]
