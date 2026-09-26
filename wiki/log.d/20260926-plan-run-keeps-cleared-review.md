# 2026-09-26 — Re-running a cleared plan no longer re-plans it

- `Stages::Plan.run!` always spawned the plan agent. On a task whose plan was
  COMPLETE and whose review had cleared, the planner edited `plan.md` again,
  the cleared review went stale ("canonical plan changed after plan review"),
  and a fresh review cycle opened, discarding nine linked plans of convergence
  on one task.
- `run!` now returns `complete` without spawning the planner when the plan
  marker is COMPLETE and the plan review allows execution and is current.
  `hive develop` is the move forward. A stale, uncleared or unreadable review
  still re-plans as before.
