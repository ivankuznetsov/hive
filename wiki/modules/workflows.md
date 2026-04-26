---
title: Hive::Workflows
type: module
source: lib/hive/workflows.rb
created: 2026-04-26
updated: 2026-04-26
tags: [module, workflow, verbs]
---

**TLDR**: Single source of truth for the five workflow verbs (`brainstorm`, `plan`, `develop`, `pr`, `archive`). Each verb advances a task from one stage to the next; `Hive::Commands::StageAction` consumes `Hive::Workflows::VERBS` directly, `Hive::TaskAction` uses it to label the "ready to <verb>" status bucket per stage, and `Hive::Commands::Approve` / `FindingToggle` use it to derive the next-action command after a successful operation. Adding or removing a verb is a one-file change.

## Constants

- `VERBS` — frozen hash, verb name → `{ source:, target:, force_source? }`. Source and target are `Hive::Stages::DIRS` entries.
- `VERB_BY_SOURCE` — reverse lookup: source stage_dir → verb. nil for `6-done` (no verb advances out).
- `VERB_BY_TARGET` — reverse lookup: target stage_dir → verb. nil for `1-inbox` (no verb arrives there; tasks are created via `hive new`).

## Public surface

```ruby
config = Hive::Workflows.for_verb("plan")
# { source: "2-brainstorm", target: "3-plan" }

verb = Hive::Workflows.verb_advancing_from("3-plan")
# "develop" — the verb that takes a task OUT of 3-plan

verb = Hive::Workflows.verb_arriving_at("3-plan")
# "plan" — the verb whose target IS 3-plan; called on a task already
# at 3-plan, StageAction's at-target branch runs the plan agent

Hive::Workflows.workflow_verb?("plan")     # true
Hive::Workflows.workflow_verb?("findings") # false (a generic verb, not workflow)
```

## Verb definitions

| Verb | Source | Target | Notes |
|------|--------|--------|-------|
| `brainstorm` | `1-inbox` | `2-brainstorm` | `force_source: true` — inbox tasks have a `:waiting` marker by template, so the marker check is bypassed for this verb only |
| `plan` | `2-brainstorm` | `3-plan` | requires `:complete` marker |
| `develop` | `3-plan` | `4-execute` | requires `:complete` marker |
| `pr` | `4-execute` | `5-pr` | requires `:execute_complete` marker |
| `archive` | `5-pr` | `6-done` | requires `:complete` marker; idempotent at 6-done |

## Why a separate module?

`StageAction` previously owned an `ACTIONS` table; `TaskAction` had its own `ACTIONS` map; `Approve#workflow_command_for` had a hard-coded `{2 => "brainstorm", …}` literal. Three sources of truth for the same five-row map. Renaming `develop` → `execute` would silently leave one of them on the old name. The shared module ensures every consumer stays in lockstep.

## Backlinks

- [[commands/run]] — workflow verb dispatch via `Hive::Commands::StageAction`
- [[modules/task_action]] — uses VERBS to build per-state next-action commands
- [[modules/stages]] — the canonical stage list this module references
