## [2026-07-17T13:10:00Z] fix — preserve task-lock identity in TUI snapshots

**Action:** Extended `Hive::Tui::Snapshot::Row` and its status-payload mapper
to retain `task_lock_pid`, `task_lock_process_start_time`, and `task_lock_id`.
The renderer still classifies rows from the strict `live_task_lock` boolean,
but the lossless snapshot now matches the additive `hive-status` v5 contract.
Added mapping assertions plus coverage for task-folder disappearance during
lock release, missing lock reads, and the healer's TERM grace loop. The full
coverage gate passed at 100.00% line coverage.
