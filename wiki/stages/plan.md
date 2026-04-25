---
title: 3-plan stage
type: stage
source: lib/hive/stages/plan.rb, templates/plan_prompt.md.erb
created: 2026-04-25
updated: 2026-04-25
tags: [stage, plan, ce-plan]
---

**TLDR**: Agent reads `brainstorm.md`, runs `/compound-engineering:ce-plan` to generate a structured `plan.md`, and waits for human review/edits via `<!-- WAITING -->` until ready (`<!-- COMPLETE -->`).

## Setup

- **State file**: `plan.md`.
- **Prompt**: `templates/plan_prompt.md.erb`, rendered with `project_name`, `task_folder`, `brainstorm_text`. Brainstorm content is wrapped in `<user_supplied content_type="brainstorm_md">…</user_supplied>`.
- **Agent invocation**: `cwd = task.folder`, `--add-dir <project_root>`, `log_label = "plan"`.
- **Budgets**: `cfg["budget_usd"]["plan"]` (default 20), `cfg["timeout_sec"]["plan"]` (default 600).

## Agent behaviour (per `templates/plan_prompt.md.erb`)

1. If `plan.md` does not exist, use the `/compound-engineering:ce-plan` skill to generate the plan with required sections:
   - `## Overview`
   - `## Requirements Trace`
   - `## Scope Boundaries`
   - `## Implementation Units` (each with goal / files / approach / test scenarios / verification)
   - `## Risks`

   End with `<!-- WAITING -->`.
2. If `plan.md` exists, integrate inline user feedback. End with `<!-- COMPLETE -->` only if no follow-up questions remain; otherwise `<!-- WAITING -->`.

Agent must not modify any file other than `plan.md`. Must not execute code in the project (execution happens in 4-execute).

## Marker → commit action mapping (`Stages::Plan.action_for`)

| Marker | Commit action |
|--------|---------------|
| `:waiting` | `draft_updated` |
| `:complete` | `complete` |
| `:error` | `error` |

## Tests

- `test/integration/run_plan_test.rb`.

## Backlinks

- [[stages/brainstorm]] · [[stages/execute]]
- [[modules/agent]] · [[modules/markers]]
- [[state-model]]
