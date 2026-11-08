# 2026-10-03 — Digest hold observer waits for the task lock

- The daemon's `DailyDigest::HoldObserver` appended `hold_recorded` activity
  (capacity, provider or authority hold active/cleared) to a task's
  `task-journal.jsonl` while that task's agent was running. Review CI-fix and
  plan-review revision run inside `ArtifactFirewall::AgentCustody`, which
  snapshots orchestrator-owned files, so the append was blamed on the agent:
  the stage failed ("modified protected files: task-journal.jsonl") and the
  entry was rolled back. Seen on the multi-dependency and read-only status
  tasks once the daemon was enabled for the hive project.
- `HoldObserver#record` returns early while `row.live_task_lock` is true.
  Its remembered state is unchanged, so the transition is recorded on the
  first tick after the lock is released.
