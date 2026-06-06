---
title: 3-plan stage
type: stage
source: lib/hive/stages/plan.rb, templates/plan_prompt.md.erb
created: 2026-04-25
updated: 2026-05-22
tags: [stage, plan, llm-wiki, ce-plan]
---

**TLDR**: Agent reads `brainstorm.md`, runs Hive's configured wiki-first planning skill to generate a structured `plan.md`, and waits for human review/edits via `<!-- WAITING -->` until ready (`<!-- COMPLETE -->`). The default is agent-aware: Claude uses `/plan`, Codex uses `$llm-wiki:wiki-plan`, and Pi receives `/skill:wiki-plan` after profile formatting.

## Setup

- **State file**: `plan.md`.
- **Prompt**: `templates/plan_prompt.md.erb`, rendered with `project_name`, `task_folder`, `brainstorm_text`, `user_supplied_tag`, and `skill_invocation`. Brainstorm content is wrapped in a nonce-tagged user-supplied block.
- **Skill resolution**: `Hive::Config.stage_skill(cfg, "plan")` picks a project override when present. If the legacy `plan.skill: /plan` alias is used with Codex or Pi, Hive maps it to llm-wiki's canonical `wiki-plan` skill.
- **Agent invocation**: `cwd = task.folder`, `add_dirs = [task.folder]`, `log_label = "plan"`.
- **Budgets**: `cfg["budget_usd"]["plan"]` (default 100), `cfg["timeout_sec"]["plan"]` (default 3600).

## Agent behaviour (per `templates/plan_prompt.md.erb`)

1. If `plan.md` does not exist, use the configured wiki-first planning skill to generate the plan with required sections:
   - `## Overview`
   - `## Requirements Trace`
   - `## Scope Boundaries`
   - `## Implementation Units` (each with goal / files / approach / test scenarios / verification)
   - `## Risks`

   End with `<!-- WAITING -->`.
2. If `plan.md` exists, integrate inline user feedback. End with `<!-- COMPLETE -->` only if no follow-up questions remain; otherwise `<!-- WAITING -->`.

Agent must not modify any file other than `plan.md`. Must not execute code in the project (execution happens in 4-execute).

If a daemon stop or killed agent leaves a zero-byte `plan.md`, or a missing `plan.md` after a `plan-*.log` shows the plan agent started, status classifies the row as `Error` with `PLAN_MISSING_OUTPUT` instead of `Needs your input`. A freshly promoted plan folder with no `plan.md` and no plan-run log still remains `Needs your input` because it is valid and runnable. `PLAN_MISSING_OUTPUT` is a synthetic markerless error, so recovery is a direct rerun: `hive plan ... --from 3-plan`; there is no `ERROR` marker to clear.

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
