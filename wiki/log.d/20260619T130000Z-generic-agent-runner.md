---
date: 2026-06-19
slug: generic-agent-runner
pages: [stages/agent, stages/index, index]
---

Added the generic descriptor-backed `Hive::Stages::Agent` runner and shared
`templates/agent_prompt.md.erb`. The runner resolves the current stage per-task
via `task.workflow.stage_named(task.stage_name)` (not the coding-pinned workflow
registry), reads prior markdown artifacts with a per-spawn nonce wrapper,
spawns one headless folder-isolated agent with `status_mode: :state_file_marker`,
and maps terminal markers to brainstorm-style commit actions.

Created [[stages/agent]], cataloged it in [[index]], and linked it from
[[stages/index]]. Coding's existing stage names remain handled by their bespoke
runners in the follow-up resolver unit.
