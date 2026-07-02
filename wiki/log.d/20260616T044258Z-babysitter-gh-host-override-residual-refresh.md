## [2026-06-16T04:42:58Z] wiki - refresh babysitter gh host override residual commit

**Action:** Refreshed LLM wiki planning/documentation coverage after commit `04631bcf` committed residual wiki edits for the babysitter dry-run `gh` host-override audit. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "babysitter gh host override dry-run wiki refresh"` surfaced existing Hive babysitter/gaps/testing/log context, and the configured master wiki path had no Hive-specific guidance. Inspected the committed diff plus current `bin/hive-babysitter-stub-gh`, `bin/hive-babysitter-stub-git`, `lib/hive/babysitter/dry_run_env.rb`, `test/unit/babysitter/dry_run_env_test.rb`, [[commands/babysit]], [[modules/babysitter]], [[testing]], and [[gaps]]. While inspecting, current worktree source/test edits expanded the same boundary to cover glued short `-R` repo selectors and `GH_HOST` / `GH_REPO` enterprise env scrubbing; the safe glued `-Rowner/repo` expectation initially failed because the classifier did not strip glued safe `-R` before read-only classification, so this refresh added that source fix before documenting the behavior.

**Coverage:** Confirmed the latest residual commit refined existing babysitter wiki/gap wording, then synced the command/module/testing docs to the current source-level dry-run boundary: `gh` host overrides are rejected anywhere in argv, host-qualified `--repo` / `-R` values skip, glued host-qualified `-R<value>` / `-R=<value>` skips, bare `OWNER/REPO` selectors remain allowed, `gh auth status` token/host selectors skip, and allowed `gh` passthrough scrubs host/repo/enterprise env selectors. Updated [[gaps]] to tie the remaining live-smoke uncertainty to the latest wiki-only commit, source commits inspected, and current worktree source/test coverage. Page coverage stayed within existing pages, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/babysit]]
- [[modules/babysitter]]
- [[testing]]
- [[gaps]]
