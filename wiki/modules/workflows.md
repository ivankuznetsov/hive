---
title: Hive::Workflows
type: module
source: lib/hive/workflows.rb, lib/hive/workflow.rb, lib/hive/workflows/registry.rb, lib/hive/workflows/coding.rb, lib/hive/workflows/descriptor_parser.rb, lib/hive/workflows/loader.rb, lib/hive/workflows/project.rb
created: 2026-04-26
updated: 2026-07-09
tags: [module, workflow, verbs, selection]
---

**TLDR**: The coding, content, and project-authored workflows are described as ordered `Hive::Workflow` value objects whose stages carry directory names, state files, incoming advance verbs, runner metadata, optional instruction files, optional permission specs, per-stage agent/model/effort overrides, council reviewer configs, and terminal deliverables. `Hive::Workflows::Registry.default` still returns the coding descriptor, and the legacy public constants (`Hive::Stages::DIRS`, `Hive::Task::STAGE_NAMES` / `STATE_FILES`, `Hive::Workflows::VERBS`) are derived from it at load time. `Hive::Task` resolves a per-task descriptor from `meta.yml workflow:` or project `default_workflow`, `Hive::WorkflowSelection` centralizes CLI validation and valid-name listing, `Hive::Workflows::Registry.all` exposes the live descriptor set for built-in, runtime/test, and active-project registrations, and `Hive::Stages::Resolver` consumes `kind: :agent` / `kind: :council` as fallbacks for non-coding stage names while coding's bespoke runners remain name-authoritative only for `:coding`. Coding's descriptor now uses runtime primitive kinds (`:execute`, `:review_council`, `:finalize`) for the worktree-coupled stages; the old `:marker` descriptor kind is retired.

## Descriptor and registry

- `Hive::Workflow` — frozen `Data` value object with `id` and ordered `stages`. Read-only lookup helpers:
  - `#stage_named(name)` — soft lookup, returns the `Stage` or nil.
  - `#state_file_for(name)` — hard lookup, raises `KeyError` on an unknown name.
  - `#stage_names` / `#stage_dirs` — frozen lists of the descriptor's stage names / `index-name` dirs.
  - `#next_stage_after(name)` — the next `Stage` in descriptor order, or nil for BOTH the terminal stage and an unknown name (consumed by `Approve#resolve_destination` and `Run`'s advance path).
  - `#advance_verb_for(name)` — the incoming advance verb name for a stage, or nil when the stage advances by bare mv (no descriptor verb) OR the name is unknown.
  - `#stage_for_dir(dir)` — soft lookup by `index-name` dir, returns the `Stage` or nil.
  - `#resolve_stage_ref(ref)` — accepts a full dir (`3-plan`) or short name (`plan`) and returns the canonical `Stage#dir` (or nil); used by `Approve` to canonicalize `--to`/`--from`.
  - `#has_stage?(ref)` — predicate wrapper around `#resolve_stage_ref`. An additive affordance (U6.3) for coding-scoped consumers to skip absent-stage behavior; it has no production call sites yet and is currently exercised only by its own unit test.
- `Hive::Workflow::Stage` — frozen stage value object. `#dir` returns `"#{index}-#{name}"`; metadata such as `kind`, `skill`, `instruction`, `permissions`, `status_mode`, `budget_usd`, `timeout_sec`, `capability`, `agent`, `model`, `effort`, `input`, `reviewers`, `council`, and `deliverable` is carried for runner selection, prompt rendering, and status classification. The generic runner path consumes `kind: :agent` (for runner selection), `state_file` (`agent.rb:20`), `skill`, `instruction`, descriptor-level `permissions`, `budget_usd`, `timeout_sec`, and per-stage `agent`/`model`/`effort` overrides. `kind: :council` routes to [[stages/council]] and carries typed `Workflow::Reviewer`, `Workflow::Council`, and optional `Workflow::Revise` values. Coding's action classifier consumes `kind: :execute`, `kind: :review_council`, and `kind: :finalize`; project-authored descriptors still expose only parser-supported user-facing kinds. As of U6 the runner also honors the descriptor's `status_mode`, falling back to `:state_file_marker` only when the stage leaves it unset (`agent.rb:53`); terminal agent/council stages can declare `deliverable` (defaulting to `state_file`) and classify as archived only when that artifact is non-empty.
- `Hive::Workflow::AdvanceVerb` — frozen value object for the verb that advances into a stage, with `force_source` and `interactive` flags defaulting false.
- `Hive::Workflows::Coding::DESCRIPTOR` — the default built-in descriptor (`id: :coding`), matching the current nine-stage pipeline exactly. Its action semantics for coding `:agent`/`:inert` stages live in `Hive::Workflows::Coding::ACTION_DISPATCH`; execute/review/finalize route by their runtime primitive kinds.
- `Hive::Workflows::Content::DESCRIPTOR` — built-in non-coding descriptor (`id: :content`) for `inbox -> research -> outline -> draft -> critique -> done`. `inbox` is inert and captures `idea.md`; every later stage is a generic `kind: :agent` stage with `status_mode: :state_file_marker`, slash-skill metadata, explicit budgets/timeouts, and `done` writing the terminal `article.md`.
- `Hive::Workflows::Registry.fetch(:coding)` / `.default` — descriptor lookup. Unknown ids raise `Hive::Workflows::UnknownWorkflow`.
- `Hive::Workflows::Registry.all` / `.ids` — live enumeration of registered descriptors/ids (`:coding`, `:content`, plus any scoped test/runtime registrations and the active project's discovered descriptors). Test helpers override this at call time so runtime-registered workflows participate in status scans and slug resolution.
- `Hive::WorkflowSelection.fetch!(name, project_root: Dir.pwd)` — CLI-facing selector validation used by [[commands/init]], [[commands/new]], and project-aware callers. Blank/nil normalizes to `coding`; unknown names raise `Hive::Workflows::UnknownWorkflow` with `valid workflows: ...` from the live registry after project descriptor discovery.

## Project-authored descriptors

Per-project descriptors live under `<hive_state_path>/workflows/*.yml`, defaulting to `.hive-state/workflows/*.yml`. `Hive::Workflows::DescriptorParser` validates YAML into `Hive::Workflow` objects:

- `id` is required, must match the filename stem, and must match `/\A[a-z0-9][a-z0-9-]*\z/`.
- user-facing `kind: agent` maps to `:agent`; `kind: terminal` maps to `:inert`; `kind: council` maps to the generic document council runner.
- stage indexes are derived from array order; non-entry stages default their incoming `advance_verb` to the stage name.
- every user-authored agent stage declares exactly one of `skill:` or `instruction:`.
- agent/council stages may declare `agent`, `model`, and `effort`, which override project stage config. They may also declare `budget_usd` and `timeout_sec` resource defaults; explicitly authored non-null project stage keys take precedence, while values introduced only by the merged config defaults do not shadow the descriptor. Budgets accept positive finite numbers, while timeouts require positive integers. Limits are per spawn rather than aggregate across a council; budgets need a profile-native flag, while timeouts also bound command reviewers/revisers.
- council stages require a `reviewers:` list; each reviewer declares exactly one of `skill`, `instruction`, `prompt`, or `command`, plus optional agent/model/effort/permissions/output basename. The `council:` block carries `quorum`, `max_rounds`, `exit_rule`, `triage_output`, and optional `revise`.
- `instruction:` paths are resolved relative to the descriptor directory and stored on the stage as absolute paths.
- `permissions:` values are validated through `Hive::PermissionScope` at load time and later passed to the generic agent runner as the explicit permission spec.
- the last stage may be inert, agent, or council. Active terminal stages require both `COMPLETE` and a non-empty deliverable before `TaskAction` classifies them as archived.

`Hive::Workflows::Loader` discovers project descriptors, and `Hive::Workflows::Project.load!(project_root)` is the idempotent boundary call. It swaps the active project overlay in `Hive::Workflows::Registry`, rejects collisions with built-in/runtime ids, and resets the memoized cross-workflow stage unions (`all_stage_dirs`, `all_stage_names`, `all_terminal_stage_dirs`). `Task`, `WorkflowSelection`, `init`, `new`, `status`, `drop`, and stage-filtered resolver paths call it before resolving workflow ids or stage refs.

`hive workflow new ID` (see [[commands/workflow]]) scaffolds the minimal `inbox -> work -> done` descriptor plus `work.md` instruction and commits those files to `hive/state`. `--template architecture` scaffolds a document-planning workflow with `inbox -> draft -> review(council) -> architecture(agent-terminal)`.

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

`Hive::Stages::Resolver.resolve(task, descriptor: Registry.default)` maps stage names to runner methods. `Hive::Commands::Run#pick_runner` passes `task.workflow`, so non-coding task folders dispatch through their own descriptor. The coding runner table is checked first only when `descriptor.id == :coding`, preserving the historical runtime for the nine coding stages even though several coding stages now carry primitive `kind:` values. A non-coding stage named `plan`, `review`, or `execute` still routes by descriptor kind instead of accidentally picking a coding bespoke runner. If the descriptor stage has `kind: :agent`, the resolver lazy-requires [[stages/agent]] and returns the generic headless runner; `kind: :council` lazy-requires [[stages/council]]. Unknown names still raise `Hive::StageError` with `no runner for stage <name>`.

## Test workflow fixture

`test/support/workflow_helpers.rb` registers a scoped `:content_fixture` descriptor for integration proof tests only. Its stages are `1-inbox -> 2-research -> 3-draft -> 4-done`; the entry is inert and the remaining stages are generic agents with `status_mode: :state_file_marker`. `with_deterministic_content_agent` stubs the generic agent seam to write deterministic state artifacts plus `<!-- COMPLETE -->`, so daemon tests exercise real init/new/status/policy/approve orchestration without network or model calls.

## Built-in content workflow

`content` is the first built-in non-coding workflow. It uses the descriptor-generic path from [[stages/agent]] and never touches coding's bespoke runner table. `hive new --workflow content` writes the topic to `1-inbox/<slug>/idea.md` and stamps the inert entry complete, making that file prior context for `research`. The terminal `6-done` stage is also `kind: :agent`; it writes `article.md`, stamps `<!-- COMPLETE -->`, and then `TaskAction` classifies the terminal complete marker as archived.

Hermetic coverage lives in `test/unit/workflows/content_test.rb`,
`test/integration/content_workflow_stage_test.rb`, and
`test/integration/content_workflow_e2e_test.rb`.

## Backlinks

- [[commands/run]] — workflow verb dispatch via `Hive::Commands::StageAction`
- [[modules/task_action]] — uses VERBS to build per-state next-action commands
- [[modules/stages]] — the canonical stage list this module references
- [[modules/task]] — task stage validation and state-file lookup derived from the descriptor-backed constants
