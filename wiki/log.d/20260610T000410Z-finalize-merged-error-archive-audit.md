## [2026-06-10T00:04:10Z] wiki — audit merged finalize error archive coverage

**Action:** Refreshed command/API and helper-module wiki coverage after commit `d05fb4c3` touched the archive workflow flag, `StageAction`, the daemon dispatcher/merge watcher, `Hive::Gh.pr_state`, and focused tests. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "merged finalize error archive pr_state stage_action daemon pr_merge_watcher"` returned no indexed hits, and the configured master wiki path had no relevant match. Inspected the committed diff plus current `lib/hive/cli.rb`, `lib/hive/commands/stage_action.rb`, `lib/hive/daemon/dispatcher.rb`, `lib/hive/daemon/pr_merge_watcher.rb`, `lib/hive/gh.rb`, and focused daemon/stage-action/GitHub tests. Corrected [[modules/daemon]] so the documented full-tick order matches source: the PR-merge watcher ticks before dispatch-request processing and per-row dispatch, so newly enqueued recoverable finalize error rows are polled on a later tick. Added coverage-gate tests for the `hive generate-name` CLI delegation and Codex stdin display-name prompt path, and documented those rows in [[testing]]. Carried forward the missing live-daemon smoke uncertainty in [[gaps]]. Page coverage count stayed 76, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/daemon]]
- [[testing]]
- [[gaps]]
