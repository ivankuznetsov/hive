## [2026-06-13T23:46:57Z] wiki — audit current-branch gh cache dry-run coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after current-branch source commit `30a9b383` changed `bin/hive-babysitter-stub-gh` and `test/unit/babysitter/dry_run_env_test.rb`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter dry-run gh api cache"` returned existing babysitter module/gap/log coverage, and direct wiki/source searches showed the pages already contained the gh-cache behavior from the equivalent earlier patch.

**Coverage:** Inspected `git diff 30a9b383^ 30a9b383`, `bin/hive-babysitter-stub-gh`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]]. Confirmed the current docs match the code: the dry-run `gh` stub skips both `gh api --cache <ttl>` and `gh api --cache=<ttl>` even when the method is explicitly GET because gh writes a local API cache, while explicit GET reads without `--cache` still pass through. The focused regression uses a fake gh binary plus `XDG_CACHE_HOME` and verifies the cache directory is not created. Updated [[gaps]] only to tie the remaining uncertainty to this current-branch audit: no in-tree live-agent `hive babysit --once PROJECT --dry-run` artifact was found. Page coverage stayed within existing babysitter pages, so [[index]] did not need a catalog edit. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[gaps]]
- [[log]]
