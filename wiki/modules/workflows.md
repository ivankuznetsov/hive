---
title: Hive::Workflows
type: module
source: lib/hive/workflows.rb, lib/hive/workflow.rb, lib/hive/workflows/registry.rb, lib/hive/workflows/coding.rb
created: 2026-04-26
updated: 2026-06-20
tags: [module, workflow, verbs]
---

**TLDR**: The coding workflow is described once as `Hive::Workflows::Coding::DESCRIPTOR`: an ordered `Hive::Workflow` value object whose stages carry directory names, state files, incoming advance verbs, and runner metadata. `Hive::Workflows::Registry.default` returns that descriptor, and the legacy public constants (`Hive::Stages::DIRS`, `Hive::Task::STAGE_NAMES` / `STATE_FILES`, `Hive::Workflows::VERBS`) are derived from it at load time. `Hive::Task` resolves a per-task descriptor from `meta.yml workflow:` or project `default_workflow`, `Hive::Workflows::Registry.all` exposes the live descriptor set for runtime/test registrations, and `Hive::Stages::Resolver` consumes `kind: :agent` as a fallback for non-coding stage names while coding's bespoke runners remain name-authoritative only for `:coding`.

## Descriptor and registry

- `Hive::Workflow` — frozen `Data` value object with `id` and ordered `stages`. Read-only lookup helpers:
  - `#stage_named(name)` — soft lookup, returns the `Stage` or nil.
  - `#state_file_for(name)` — hard lookup, raises `KeyError` on an unknown name.
  - `#stage_names` / `#stage_dirs` — frozen lists of the descriptor's stage names / `index-name` dirs.
  - `#next_stage_after(name)` — the next `Stage` in descriptor order, or nil for BOTH the terminal stage and an unknown name (consumed by `Approve#resolve_destination` and `Run`'s advance path).
  - `#advance_verb_for(name)` — the incoming advance verb name for a stage, or nil when the stage advances by bare mv (no descriptor verb) OR the name is unknown.
  - `#stage_for_dir(dir)` — soft lookup by `index-name` dir, returns the `Stage` or nil.
  - `#resolve_stage_ref(ref)` — accepts a full dir (`3-plan`) or short name (`plan`) and returns the canonical `Stage#dir` (or nil); used by `Approve` to canonicalize `--to`/`--from`.
  - `#has_stage?(ref)` — predicate wrapper around `#resolve_stage_ref`. An additive affordance (U6.3) for coding-scoped consumers to skip absent-stage behavior; it has no production call sites yet (the U6 literal-routing sweep used `coding_workflow?` / `== :coding` guards instead) and is currently exercised only by its own unit test.
- `Hive::Workflow::Stage` — frozen stage value object. `#dir` returns `"#{index}-#{name}"`; metadata such as `kind`, `skill`, `status_mode`, `budget_usd`, and `timeout_sec` is carried for runner selection and prompt rendering. The generic runner path consumes `kind: :agent` (for runner selection), `state_file` (`agent.rb:20`), `skill`, `budget_usd`, and `timeout_sec` (defaulting to `DEFAULT_TIMEOUT_SEC` when both cfg and descriptor omit it). As of U6 the runner also honors the descriptor's `status_mode`, falling back to `:state_file_marker` only when the stage leaves it unset (`agent.rb:35`). The speculative `capability` field was dropped (no producer, no consumer).
- `Hive::Workflow::AdvanceVerb` — frozen value object for the verb that advances into a stage, with `force_source` and `interactive` flags defaulting false.
- `Hive::Workflows::Coding::DESCRIPTOR` — the only built-in descriptor (`id: :coding`), matching the current nine-stage pipeline exactly.
- `Hive::Workflows::Registry.fetch(:coding)` / `.default` — descriptor lookup. Unknown ids raise `Hive::Workflows::UnknownWorkflow`.
- `Hive::Workflows::Registry.all` / `.ids` — live enumeration of registered descriptors/ids. Test helpers override this at call time so runtime-registered workflows participate in status scans and slug resolution.

## Constants

- `VERBS` — frozen hash, verb name → `{ source:, target:, force_source?, interactive? }`. It is derived by walking adjacent stages in `Registry.default`; false `force_source` / `interactive` flags are omitted entirely to preserve the historical hash shape.
- `VERB_BY_SOURCE` — reverse lookup: source stage_dir → verb. nil for `9-done` (no verb advances out).
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
Hive::Workflows.all_stage_dirs             # union across Registry.all
Hive::Workflows.all_stage_names            # union across Registry.all
```

## Verb definitions

| Verb | Source | Target | Notes |
|------|--------|--------|-------|
| `brainstorm` | `1-inbox` | `2-brainstorm` | `force_source: true` — inbox tasks have a `:waiting` marker by template, so the marker check is bypassed for this verb only |
| `plan` | `2-brainstorm` | `3-plan` | requires `:complete` marker |
| `develop` | `3-plan` | `4-execute` | requires `:complete` marker |
| `open-pr` | `4-execute` | `5-open-pr` | requires `:execute_complete` marker |
| `review` | `5-open-pr` | `6-review` | requires `:complete` marker |
| `artifacts` | `6-review` | `7-artifacts` | requires `:review_complete` marker |
| `finalize` | `7-artifacts` | `8-finalize` | requires `:complete` marker |
| `archive` | `8-finalize` | `9-done` | requires `:complete` marker; idempotent at 9-done |

## Why a separate module?

`StageAction` previously owned an `ACTIONS` table; `TaskAction` had its own `ACTIONS` map; `Approve#workflow_command_for` had a hard-coded `{2 => "brainstorm", …}` literal. Three sources of truth for the same map meant renaming a verb could silently leave one consumer on the old value. The shared `VERBS` module-level API fixed that drift class; the descriptor now moves the stage dirs, task state-file map, and verb adjacency behind the same ordered source while keeping the old constants for callers.

## Runner Selection

`Hive::Stages::Resolver.resolve(task, descriptor: Registry.default)` maps stage names to runner methods. `Hive::Commands::Run#pick_runner` passes `task.workflow`, so non-coding task folders dispatch through their own descriptor. The coding runner table is checked first only when `descriptor.id == :coding`, preserving the historical runtime for the nine coding stages while allowing a non-coding stage named `plan`, `review`, or `execute` to route by descriptor kind instead of accidentally picking a coding bespoke runner. If the descriptor stage has `kind: :agent`, the resolver lazy-requires [[stages/agent]] and returns the generic headless runner. Unknown names still raise `Hive::StageError` with `no runner for stage <name>`.

## Backlinks

- [[commands/run]] — workflow verb dispatch via `Hive::Commands::StageAction`
- [[modules/task_action]] — uses VERBS to build per-state next-action commands
- [[modules/stages]] — the canonical stage list this module references
- [[modules/task]] — task stage validation and state-file lookup derived from the descriptor-backed constants
