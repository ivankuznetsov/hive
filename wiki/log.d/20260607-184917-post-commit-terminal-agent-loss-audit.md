## [2026-06-07T18:49:17Z] wiki — audit late-stage terminal agent-loss retry coverage

**Action:** Refreshed wiki planning/documentation coverage after commit `0dde0c69` extended `Hive::Daemon::StaleAgentHealer` and already touched daemon, artifacts, finalize, testing, gaps, and log pages. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "stale agent healer terminal agent loss retry artifacts finalize tmux_session_terminated agent_orphaned"` surfaced existing daemon/log coverage, and the configured master wiki path had no matching context. Inspected the committed diff plus current `lib/hive/daemon/stale_agent_healer.rb`, `lib/hive/stages/artifacts.rb`, `lib/hive/stages/finalize.rb`, `lib/hive/stages/base.rb`, `lib/hive/claude_launcher.rb`, `lib/hive/markers.rb`, and focused stale-healer/status tests. Confirmed the committed page updates were source-synced, then refreshed cross-reference pages that still implied all daemon `error` rows are manual skips: [[cli]], [[commands/daemon]], [[stages/index]], and [[state-model]]. Refined [[gaps]] to record that the new late-stage terminal agent-loss retry path remains unit-pinned only; no live or integration artifact proves the full status -> healer clear -> redispatch loop for artifacts/finalize tmux loss. Page count stayed 75, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[cli]]
- [[commands/daemon]]
- [[stages/index]]
- [[state-model]]
- [[gaps]]
