## [2026-06-08T11:39:52Z] tui — refresh immediately when task lock changes

**Action:** Fixed a TUI stale-status window where a task could keep rendering as `Needs your input` after its answered row had already been picked up by a live runner. Root cause: `Hive::Tui::StateSource` cached status snapshots by registry/stage/state-file mtimes but did not include each task's `.lock`; a runner can acquire that lock before `AGENT_WORKING` is written, and `Hive::TaskAction` intentionally classifies a live lock as `agent_running`. The fingerprint now watches `<task>/.lock` so lock creation, update, and removal force an immediate status reparse. Added StateSource coverage for lock appearance, disappearance, and mtime updates.

**Refreshed pages:**
- [[commands/tui]]
