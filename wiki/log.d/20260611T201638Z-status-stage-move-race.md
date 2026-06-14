## [2026-06-11T20:16:38Z] status/tui — transient stage-move race coverage

**Action:** Refreshed command/API wiki coverage after commits `bd0b965a`, `4099bbc4`, and `520660e9` touched `Hive::Commands::Status`. Read `AGENTS.md`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `.llm-wiki/config.json` points at `/home/asterio/wikis/master/wiki`, and `qmd search "status vanished task folders Errno::ENOENT stage_task_entries"` returned no indexed hits. Inspected the committed diffs plus current `lib/hive/commands/status.rb`, `test/unit/commands/status_test.rb`, `test/integration/status_test.rb`, [[commands/status]], [[commands/tui]], [[state-model]], and [[testing]]. Documented the status scan's `Errno::ENOENT` tolerance for vanished task folders, the `stage_task_entries` seam, the duplicate-slug cleanup that drops only rows whose folders no longer exist, and the TUI implication that normal stage moves should not render a one-poll duplicate row. Recorded that this race is now covered by focused unit regressions, while live TUI/daemon smoke evidence remains absent. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/status]]
- [[commands/tui]]
- [[gaps]]
