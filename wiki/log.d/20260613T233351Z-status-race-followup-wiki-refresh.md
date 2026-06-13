## [2026-06-13T23:33:51Z] status/tui — refresh stage-move race follow-up coverage

**Action:** Refreshed command/API wiki coverage after the later status-race follow-up commits on the branch (`ff0cdbf5`, `7fd2bc65`, `aaba74be`, `4f85b423`, and `10b91bce`) narrowed `Hive::Commands::Status#collect_rows`'s `InvalidTaskPath` rescue, clarified the folder-level `ENOENT` re-raise contract, and added focused unit coverage for non-finalize forward moves, surviving-folder state-file `ENOENT`, the race test double's `to_path` timing, and three-member duplicate pruning. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "command API routes handlers commands executable entrypoints README post commit"` surfaced prior wiki-refresh context, and the configured master wiki path had no relevant project-specific hit. Inspected the committed diffs plus current `lib/hive/commands/status.rb`, `test/unit/commands/status_test.rb`, [[commands/status]], [[commands/tui]], [[testing]], and [[gaps]]. Updated the status/TUI pages to distinguish forward same-scan resurfacing from backward one-poll disappearance and to record that surviving-folder `ENOENT` propagates as a real status failure. Carried forward the uncertainty that no live daemon/TUI polling artifact proves the behavior during a real stage transition. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/status]]
- [[commands/tui]]
- [[testing]]
- [[gaps]]
