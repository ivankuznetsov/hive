## [2026-06-07T15:05:00Z] daemon — auto-heal interrupted finalize push leftovers

**Action:** Extended `Hive::Daemon::StaleAgentHealer` so `8-finalize` rows with `ERROR reason=unpushed_commits` and no live task lock are automatically cleared with a bounded per-process retry budget. The clear uses the observed `marker_id` when present, falling back to legacy no-id markers only, so a stale status row cannot erase a newer same-reason error marker. After a successful clear, the healer seeds the controller's edit-resume baseline with the pre-clear state-file mtime; the next status read sees the marker-clear rewrite as newer than that baseline and dispatches finalize after the normal debounce instead of first-sight `record_baseline` stranding the row. The retry does not push directly inside the healer; it lets the normal daemon dispatch rerun finalize, preserving the existing clean-exit scope check, residue auto-commit path, GitHub auth check, and push validation. Manual-only finalize errors such as `ensure_clean_on_exit_failed` remain red for operator inspection, and repeated push failures stay red after the budget is exhausted.

**Tests:** Added focused unit coverage for unpushed finalize auto-recovery, live-lock skip, non-finalize skip, manual clean-exit skip, retry-budget exhaustion, and marker-clear failure logging. Verified `test/unit/daemon/stale_agent_healer_test.rb`, `test/unit/task_action_test.rb`, and `test/integration/run_finalize_test.rb`.

**Refreshed pages:**
- [[modules/daemon]]
- [[stages/finalize]]
- [[testing]]
