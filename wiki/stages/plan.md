---
title: 3-plan stage
type: stage
source: lib/hive/stages/plan.rb, templates/plan_prompt.md.erb
created: 2026-04-25
updated: 2026-08-12
tags: [stage, plan, llm-wiki, ce-plan, critique, dependencies]
---

**TLDR**: Agent reads `brainstorm.md`, runs Hive's configured wiki-first planning skill to generate a structured `plan.md`, and waits for human review/edits via `<!-- WAITING -->` until ready (`<!-- COMPLETE -->`). A readable built-in coding plan then enters the conditional [[modules/plan_review]] substate before execute: `skip`, `standard`, or `mandatory` policy evidence and a current resolution—not the marker alone—authorize `4-execute`. The default planner is agent-aware: Claude uses `/plan`, Codex uses `/llm-wiki:wiki-plan`, and Pi receives `/skill:wiki-plan` after profile formatting.

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

If planning identifies a known prerequisite, the agent writes it as optional
top-level YAML frontmatter using the same scalar syntax as task metadata:

```yaml
---
depends_on: api:base-task-260716-abcd
---
```

`meta.yml` remains authoritative. Plan frontmatter is a drift assertion, not a
second scheduling edge: it may be absent even when metadata has a dependency,
but when present it must exactly match metadata after normalization. A
plan-only, mismatched, or malformed declaration becomes an admission error at
status/run/forward-approve. Hive does not inspect plan prose for ordering.

If a daemon stop or killed agent leaves a zero-byte `plan.md`, or a missing `plan.md` after a `plan-*.log` shows the plan agent started, status classifies the row as `Error` with `PLAN_MISSING_OUTPUT` instead of `Needs your input`. A freshly promoted plan folder with no `plan.md` and no plan-run log still remains `Needs your input` because it is valid and runnable. `PLAN_MISSING_OUTPUT` is a synthetic markerless error, so recovery is a direct rerun: `hive plan ... --from 3-plan`; there is no `ERROR` marker to clear.

If the headless planner returns with either a zero exit or an unavailable
captured exit status without replacing Hive's pre-spawn `AGENT_WORKING` marker,
`Hive::Agent` writes
`ERROR reason=agent_exited_without_terminal_marker` with the observed marker
and provider. The plan action therefore fails instead of emitting a successful
stage envelope that a following `develop` call cannot advance. The shared
recovery coordinator retries this error through the same guarded lifecycle as
other persisted agent failures.

When the plan agent writes a recoverable terminal `ERROR`, the daemon's sole
automatic scheduler submits it after the shared cooldown. `RecoveryCoordinator`
persists the generation-bound v5 request before the sole guarded marker
transition and derives
`hive plan <slug> --project <project> --from 3-plan` as the owning workflow
retry. This covers agent loss, provider limits, timeouts, and every other
persisted reason without a stage-specific healer branch, counter, or
clear-then-requeue window.

## Conditional critique substate

After a regular readable `plan.md` exists, `Stages::Plan` captures the planner
provider/model/family/effort and invokes `PlanReview::Orchestrator`. A strict
low-risk plan writes a no-call `skipped` resolution. Standard and mandatory
plans run a disposable `ce-doc-review` whole-document leg, a separately routed
independent adversarial leg, typed finding decisions, at most one revision by
the captured planner, and one verification critique. Reviewer output cannot
write canonical `plan.md`.

`plan-review/current.json` is the authority projection. Its terminal states are
`skipped`, `cleared`, standard-only `degraded_cleared`, or `blocked`; open
gated/manual findings, missing mandatory coverage, stale plan/policy identity,
or corrupt artifacts keep execution disabled. `<!-- COMPLETE -->` remains a
coarse workflow signal and may be flipped only after the same current review is
verified. Use `hive plan-review-run TARGET` for non-authority progress and the
freshness-bound `hive plan-review TARGET ACTION ...` surface for explicit
approvals, answers, waivers, raises, retries, or downgrades.

## Marker → commit action mapping (`Stages::Plan.action_for`)

| Marker | Commit action |
|--------|---------------|
| `:waiting` | `draft_updated` |
| `:complete` | `complete` |
| `:error` | `error` |

## Tests

- `test/integration/run_plan_test.rb`.
- `test/integration/plan_review_lifecycle_test.rb` and
  `test/unit/plan_review/` pin policy, critique, revision, verification,
  decisions, lineage, and clearance.
- `test/unit/plan_frontmatter_test.rb` and `test/integration/dependency_admission_test.rb` pin structured dependency parsing and plan/metadata drift.

## Backlinks

- [[stages/brainstorm]] · [[stages/execute]]
- [[modules/agent]] · [[modules/markers]] · [[modules/plan_review]]
- [[state-model]]
