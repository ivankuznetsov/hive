## [2026-06-07T14:17:52Z] wiki — audit finalize unpushed auto-retry coverage

**Action:** Refreshed wiki planning/documentation coverage after the finalize unpushed auto-retry change updated `Hive::Daemon::StaleAgentHealer`, focused unit tests, and the daemon/finalize/testing wiki pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "finalize unpushed commits stale healer auto retry"` found only existing CLI/log context, and the configured master wiki path had no relevant Hive context. Inspected the committed diff and current `lib/hive/daemon/stale_agent_healer.rb`, `lib/hive/daemon/dispatcher.rb`, `lib/hive/stages/finalize.rb`, `lib/hive/gh.rb`, `lib/hive/task_action.rb`, `test/unit/daemon/stale_agent_healer_test.rb`, `test/integration/daemon_stale_agent_healing_test.rb`, and `test/integration/run_finalize_test.rb`. The existing [[modules/daemon]] and [[stages/finalize]] updates were source-synced; refreshed [[testing]] to include the existing status-to-healer integration test, and recorded missing live-daemon retry evidence in [[gaps]]. Page count stayed 74, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[testing]]
- [[gaps]]
