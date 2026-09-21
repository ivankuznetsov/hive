---
title: Hive::Task
type: module
source: lib/hive/task.rb, lib/hive/task_meta.rb, lib/hive/task_counter.rb
created: 2026-04-25
updated: 2026-08-13
tags: [model, task, parsing, task-id, dependencies, workflows]
---

**TLDR**: Value object and sidecar helpers for task identity. `Hive::Task` turns a task folder path into a structured `(project_root, hive_state_path, stage_index, stage_name, slug, workflow)` tuple plus derived paths; `Hive::TaskMeta` reads `<task>/meta.yml` identity, dependency, and workflow-selector metadata; `Hive::TaskCounter` allocates global numeric ids for newly captured tasks.

## Constants

- `STAGE_NAMES = %w[inbox brainstorm plan execute open-pr review artifacts finalize done]` — 9 stages post-artifacts insertion, derived from `Hive::Workflows::Registry.default`. `open-pr` is hyphenated; the dash must be allowed by `PATH_RE`.
- `STATE_FILES` — maps stage name → state file basename (`idea.md`, `brainstorm.md`, `plan.md`, `task.md`, `pr.md`, `task.md`, `artifact.md`, `pr.md`, `task.md`), derived from the same ordered workflow descriptor.
- `PATH_RE = %r{\A(?<root>.+)/(?<state_dir>\.hive-state)/stages/(?<stage_idx>\d+)-(?<stage_name>[a-z][a-z0-9-]*)/(?<slug>[a-z][a-z0-9-]{0,62}[a-z0-9])/?\z}` — the only validator for task paths. The `[a-z][a-z0-9-]*` class for `stage_name` (no `\w+`) is what permits the dash in `5-open-pr`.

## Constructor (`#initialize(folder)`)

1. `File.expand_path(folder)`.
2. Match `PATH_RE`; on failure, raise `Hive::InvalidTaskPath` with the offending path.
3. Strip a trailing `/`, then capture into `@folder`, `@project_root`, `@state_dir_basename`, `@hive_state_path`, `@stage_index`, `@stage_name`, `@slug`.
4. Resolve `@workflow` from `<task>/meta.yml workflow:`, then project config `default_workflow`, then built-in `coding`. Missing/malformed `meta.yml` returns nil selector; recoverable broken project config falls back to `coding` with a warning. Unsupported project root keys are not recoverable: their `UnsupportedProjectConfigError` propagates as exit 78 before task-only commands can mutate state. Unknown workflow ids are re-raised as `InvalidTaskPath` so one bad task is skipped like a bad stage directory.
   Managed task resolution keeps the same strict exception; it converts other
   managed configuration failures to `InvalidTaskPath` but never converts an
   unsupported project root key to exit 64.
   A managed task must match the workflow's selected source, manifest, and
   configuration digests. Historical pins are not executable: Hive raises an
   `InvalidTaskPath` instruction to run `hive migrate`, whose dedicated
   migration boundary reads the old descriptor and moves/repins the task to
   the selected semantic stage. Loading the selected immutable snapshot for
   status, history, or task inspection does not resolve or compare its saved
   agent profile against the current process: a later agent rename, capability
   change, or compatible upgrade must not make a retained task unreadable.
   Launch-time context repeats the selection check and verifies the current
   capabilities and fingerprint only for the executable actor slot about to
   run, so a task object created immediately before an update cannot dispatch
   the superseded package and a genuinely drifted launch still fails closed.
5. Validate the parsed stage name and numeric prefix against the selected
   descriptor. A policy-only repin may retain an existing directory when that
   directory is the exact terminal stage of another registered descriptor.
   In that case `#workflow` remains the newly selected policy source and
   `#action_workflow` supplies state-file/action/archive classification from
   the folder-owning descriptor. A durable completion clock or distinct
   terminal state-file evidence preserves terminal ownership across an
   overlapping nonterminal policy stage without reclassifying a genuine active
   task whose layout is identical. When terminal directories overlap, existing
   state-file evidence selects the owner and the workflow id supplies a
   deterministic fallback. Other mismatches raise `InvalidTaskPath`.

`@hive_state_path` is the *project-rooted* hive-state path: `<project_root>/<state_dir_basename>` — always `<project_root>/.hive-state` in MVP.

## Derived accessors

| Method | Returns |
|--------|---------|
| `#project_name` | `File.basename(@project_root)` |
| `#workflow` | Selected `Hive::Workflow` descriptor |
| `#action_workflow` | Descriptor that owns the current folder for state/action classification; normally identical to `#workflow` |
| `#stage_names` | Stage names from `#workflow`, not necessarily `Task::STAGE_NAMES` |
| `#state_file` | `File.join(folder, action_workflow.state_file_for(stage_name))` |
| `#reviews_dir` | `File.join(folder, "reviews")` |
| `#worktree_yml_path` | `File.join(folder, "worktree.yml")` |
| `#meta_yml_path` | `Hive::TaskMeta.path(folder)` |
| `#id` | Numeric id from `meta.yml`, or nil when absent/malformed/unallocated |
| `#display_name` | `display_name` from `meta.yml`, or nil |
| `#depends_on` | Single same-project id/slug or explicit `project:slug` prerequisite from `meta.yml`, or nil |
| `#log_dir` | `File.join(@hive_state_path, "logs", @slug)` |
| `#commit_lock_file` | `File.join(@hive_state_path, ".commit-lock")` |

## Worktree path resolution (`#worktree_path`)

Returns `nil` for stage indexes < 4 (no worktree before execute).

For stages 4 and later:
1. If `worktree.yml` exists in the task folder, return `data["path"]` from it (the canonical pointer).
2. Otherwise fall back to `derive_worktree_path`: `<cfg["worktree_root"] || ~/Dev/<project_name>.worktrees>/<slug>`. This is the path that *would* be assigned, useful before `worktree.yml` is written.

## Why a class, not a module

`Task` carries identity (`@folder`, `@slug`, `@stage_name`) — it's a value object. All other path-like helpers are derived. `Markers`, `Lock`, `Config` etc. are stateless modules.

## Task metadata helpers

`Hive::TaskMeta` (`lib/hive/task_meta.rb`) owns the optional `<task>/meta.yml` sidecar:

- `read(task_folder)` returns the identity/workflow fields plus optional
  `plan_review_required: true`; it is total over missing, malformed, or
  non-Hash YAML.
- `read_for_admission(task_folder)` returns a result-bearing strict read. It distinguishes an absent legacy sidecar from unreadable YAML, a non-mapping document, and an invalid dependency reference; admission code must use this path rather than interpreting tolerant-read nil as “no dependency.”
- `write(..., plan_review_required: nil)` preserves the ordinary identity and
  workflow fields, accepts only literal `true` for the plan-review flag, and
  writes through `.<meta>.tmp.<pid>.<hex>` plus `File.rename`. It has no second
  metadata mutex: supported mutations already hold the shared task lease;
  identity creation and explicit legacy migration are bootstrap boundaries.
- `plan_review_required?(task_folder)` strictly distinguishes migrated/new
  pre-execute coding tasks from legacy execute tasks. Absence is the durable
  compatibility shape; malformed values fail closed.
- `update_display_name(task_folder, name)` preserves the existing id, slug, `depends_on`, and `workflow`, defaulting slug to `File.basename(task_folder)` only when the sidecar is absent. It refuses corrupt input.
- `update_id(task_folder, id)` preserves slug, display name, `depends_on`, and `workflow`, and likewise refuses corrupt input; explicit migration cannot sanitize dependency evidence by replacing a damaged mapping.

`Hive::TaskCounter` (`lib/hive/task_counter.rb`) owns the installation-scoped
`installations.next_task_id` SQLite column:

- `next!` returns the current value and increments it in one immediate
  transaction, so competing processes cannot duplicate an id.
- `next_or_nil` returns nil only when the typed runtime-control-plane mutation
  is unavailable, for capture paths repairable by `hive migrate`.
- `peek` returns the stored next value, inferring a floor above numeric task subject IDs before first use.
- `seed_at_least!(next_id)` advances the counter floor without moving it backwards.

## Tests

- `test/unit/task_test.rb` — path parsing, descriptor-driven stage/index validation, workflow selection fallback, derived-path correctness, slug edge cases, and `meta.yml` readers. `test/integration/honeycomb_workflow_lifecycle_test.rb` proves a saved managed task remains readable after agent-profile drift while runtime preparation still rejects that actor.
- `test/unit/task_meta_test.rb` — tolerant and strict sidecar reads, dependency validation, workflow selector preservation, corrupt-input mutation refusal, display-name updates, and id backfill.
- `test/unit/task_counter_test.rb` — first/sequential ids, seeding, fail-soft
  unavailability, and real forked contention.

## Backlinks

- [[modules/markers]] · [[modules/lock]] · [[modules/worktree]]
- [[modules/task_dependencies]] · [[modules/workflows]]
- [[commands/run]] · [[commands/status]]
- [[state-model]]
