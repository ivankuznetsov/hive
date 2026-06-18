---
date: 2026-06-18
slug: task-dependencies
pages: [modules/task_dependencies, modules/task, commands/status, modules/worktree, index]
---

Added same-project task dependency support around `depends_on` metadata,
central `Hive::Dependencies` resolution, status JSON/text surfacing, daemon
dispatch gating, and stacked worktree/PR base selection.

Documented the feature in [[modules/task_dependencies]], refreshed
[[modules/task]] for the `depends_on` sidecar field, refreshed
[[commands/status]] for `hive-status` v4 dependency fields and blocked
indicators, and refreshed [[modules/worktree]] for dependency branch base
overrides. Updated [[index]] because the task-dependencies page is new.

Verified the implementation with focused unit/integration groups covering
task metadata, dependency resolution/config, status/TUI/daemon gating, and
stacked branch/PR behavior.
