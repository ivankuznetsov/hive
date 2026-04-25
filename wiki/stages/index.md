---
title: Stages Index
type: index
source: lib/hive/stages/
created: 2026-04-25
updated: 2026-04-25
tags: [stage, index]
---

**TLDR**: Six pipeline stages, two of which are inert (1-inbox, 6-done) and four of which spawn `claude -p` agents. Each has exactly one state file and one runner module.

| Stage | Runner | State file | Spawns claude? | Page |
|-------|--------|------------|----------------|------|
| 1-inbox | `Hive::Stages::Inbox` | `idea.md` | no | [[stages/inbox]] |
| 2-brainstorm | `Hive::Stages::Brainstorm` | `brainstorm.md` | yes | [[stages/brainstorm]] |
| 3-plan | `Hive::Stages::Plan` | `plan.md` | yes | [[stages/plan]] |
| 4-execute | `Hive::Stages::Execute` | `task.md` (+ `worktree.yml`, `reviews/`) | yes (impl + reviewer) | [[stages/execute]] |
| 5-pr | `Hive::Stages::Pr` | `pr.md` | yes (unless idempotent) | [[stages/pr]] |
| 6-done | `Hive::Stages::Done` | `task.md` | no | [[stages/done]] |

All four active stages share `Hive::Stages::Base.spawn_agent` for the `claude -p` invocation and `Hive::Stages::Base.render(template_name, bindings)` for ERB prompt rendering.

## Backlinks

- [[architecture]] · [[state-model]] · [[cli]] · [[commands/approve]]
