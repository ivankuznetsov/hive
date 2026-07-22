---
title: Hive::Workflows
type: module
source: lib/hive/workflows.rb, lib/hive/workflow.rb, lib/hive/workflows/registry.rb, lib/hive/workflows/coding.rb, lib/hive/workflows/content.rb, lib/hive/workflows/bench.rb, lib/hive/workflows/descriptor_parser.rb, lib/hive/workflows/loader.rb, lib/hive/workflows/project.rb, lib/hive/workflow_package/
created: 2026-04-26
updated: 2026-07-21
tags: [module, workflow, verbs, selection, honeycomb, registry]
---

**TLDR**: The coding, content, bench, and project-authored workflows are described as ordered `Hive::Workflow` value objects whose stages carry directory names, state files, incoming advance verbs, runner metadata, optional instruction files, optional permission specs, per-stage agent/model/effort overrides, council reviewer configs, and terminal deliverables. `Hive::Workflows::Registry.default` still returns the coding descriptor, and the legacy public constants (`Hive::Stages::DIRS`, `Hive::Task::STAGE_NAMES` / `STATE_FILES`, `Hive::Workflows::VERBS`) are derived from it at load time. `Hive::Task` resolves a per-task descriptor from `meta.yml workflow:` or project `default_workflow`, `Hive::WorkflowSelection` centralizes CLI validation and valid-name listing, `Hive::Workflows::Registry.all` exposes the live descriptor set for built-in, runtime/test, and active-project registrations, and `Hive::Stages::Resolver` consumes `kind: :agent` / `kind: :council` as fallbacks for non-coding stage names while coding's bespoke runners remain name-authoritative only for `:coding`. Coding's descriptor now uses runtime primitive kinds (`:execute`, `:review_council`, `:finalize`) for the worktree-coupled stages; the old `:marker` descriptor kind is retired.

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
- `Hive::Workflows::Bench::DESCRIPTOR` — built-in hive-bench descriptor (`id: :bench`) for `inbox -> extract -> generate -> judge -> publish -> done`. The four generic agent stages use packaged instructions under `templates/builtins/bench/` and pin their lightweight shell-control work to Codex rather than consuming the Claude account being benchmarked. Extract/publish allow one hour; generate/judge allow seven days so a serialized campaign is not killed by the generic one-hour fallback. Generate distinguishes provider-only pending cells from real failures: the former write `ERROR reason=limits_reached retry_after=...` for daemon cooldown retry, while missing, malformed, contradictory, or non-limit failed cells remain manual `WAITING`. `Hive::Workflows::Bench.install_runtime!` snapshots the packaged campaign example, runner image, and harness into `.hive-state/bench-runtime` and commits it on `hive/state`, so `hive init . --workflow bench` needs neither a project-local descriptor nor a separate hive-bench checkout. The packaged candidate registry includes serialized Sol-plan/Terra-execute, Fable-plan/Grok-execute, and Sol-plan/Grok-execute comparisons with a sole Sol `ce-code-review` reviewer. Per-stage Codex model/effort pins are applied by the runtime shim; generate selects the Codex-0.144+ `sol` image for any GPT-5.6 stage, and that image also carries Grok for mixed cells.
- `Hive::Workflows::Registry.fetch(:coding)` / `.default` — descriptor lookup. Unknown ids raise `Hive::Workflows::UnknownWorkflow`.
- `Hive::Workflows::Registry.all` / `.ids` — live enumeration of registered descriptors/ids (`:coding`, `:content`, `:bench`, plus any scoped test/runtime registrations and the active project's discovered descriptors). Test helpers override this at call time so runtime-registered workflows participate in status scans and slug resolution.
- `Hive::WorkflowSelection.fetch!(name, project_root: Dir.pwd)` — CLI-facing selector validation used by [[commands/init]], [[commands/new]], and project-aware callers. Blank/nil normalizes to `coding`; unknown names raise `Hive::Workflows::UnknownWorkflow` with `valid workflows: ...` from the live registry after project descriptor discovery.

## Project-authored descriptors

Per-project descriptors live under `<hive_state_path>/workflows/*.yml`, defaulting to `.hive-state/workflows/*.yml`. `Hive::Workflows::DescriptorParser` validates YAML into `Hive::Workflow` objects:

- `id` is required, must match the filename stem, and must match `/\A[a-z0-9][a-z0-9-]*\z/`.
- user-facing `kind: agent` maps to `:agent`; `kind: terminal` maps to `:inert`; `kind: council` maps to the generic document council runner.
- stage indexes are derived from array order; non-entry stages default their incoming `advance_verb` to the stage name.
- every user-authored agent stage declares exactly one of `skill:` or `instruction:`.
- agent/council stages may declare `agent`, `model`, and `effort`, which override project stage config. They may also declare `budget_usd` and `timeout_sec` resource defaults; explicitly authored non-null project stage keys take precedence, while values introduced only by the merged config defaults do not shadow the descriptor. Budgets accept positive finite numbers, while timeouts require positive integers. Limits are per spawn rather than aggregate across a council; budgets need a profile-native flag, while timeouts also bound command reviewers/revisers.
- council stages require a `reviewers:` list; each reviewer declares exactly one of `skill`, `instruction`, `prompt`, or `command`, plus optional agent/model/effort/permissions/output basename. The `council:` block carries `quorum`, `max_rounds`, `exit_rule`, `on_max_rounds` (`wait` by default or `complete` for a bounded downstream delivery), `triage_output`, and optional `revise`.
- `instruction:` paths are resolved relative to the descriptor directory and stored on the stage as absolute paths.
- `permissions:` values are validated through `Hive::PermissionScope` at load time and later passed to the generic agent runner as the explicit permission spec.
- the last stage may be inert, agent, or council. Active terminal stages require both `COMPLETE` and a non-empty deliverable before `TaskAction` classifies them as archived.
- `workspace: worktree` plus `handoff: draft_pr` is one closed terminal-agent
  contract. Both fields must appear together and both `state_file` and
  `deliverable` must equal task-root `fix-report.md`. Parser and managed-package
  validation reject every partial or alternate shape, including workflows
  constructed directly in Ruby rather than parsed from YAML.

`Hive::Workflows::Loader` discovers project descriptors, and `Hive::Workflows::Project.load!(project_root, config: nil)` is the idempotent boundary call. Callers that already resolved the project config may pass it so descriptor discovery does not parse the same file again; legacy callers keep the self-loading behavior. It swaps the active project overlay in `Hive::Workflows::Registry`, rejects collisions with built-in/runtime ids, and resets the memoized cross-workflow stage unions (`all_stage_dirs`, `all_stage_names`, `all_terminal_stage_dirs`). The self-loading path resolves `hive_state_path` from the shared raw project-config reader, installs one fingerprinted overlay, then validates strict root keys against that overlay; it does not call `Config.load` recursively. For command paths that load `Project` without the aggregate `hive/workflows` entrypoint, strict validation derives its stage-name union directly from `Registry.all`, so behavior does not depend on require order. `Config.load` reuses the active overlay when it needs project stage names. `Task`, `WorkflowSelection`, `init`, `new`, `status`, `drop`, and stage-filtered resolver paths call it before resolving workflow ids or stage refs.

The one compatibility exception is an exact semantic match for the project-local
`bench.yml` shipped before `bench` became built in. Hive temporarily keeps that
legacy descriptor active so existing benchmark tasks remain visible and runnable,
and emits a one-time `hive init PROJECT --workflow bench` migration hint. The
explicit re-init archives the descriptor as
`workflows/bench.legacy.yml.disabled`, copies its instruction directory to
`workflows/bench.legacy` while retaining the original path for any sibling
descriptors that share those instructions, installs the packaged bench runtime,
and binds `default_workflow: bench` in the same lock-scoped commit. It then resets
the in-process project overlay so subsequent resolution uses the built-in
descriptor without a manual cache reset. Migration rejects symlinked workflow,
descriptor, and instruction roots and verifies that each resolves beneath the
hive-state worktree before copying. Instructions are copied into a private
staging directory and atomically published so a raced archive-target symlink is
refused without traversal. Descriptor parsing and archival are bound to one
captured inode/content snapshot, while all workflow archive operations and
rollback use a validated pinned directory handle; atomically replacing
`bench.yml` or the `workflows/` parent therefore fails closed rather than
reclassifying or traversing the replacement. The descriptor entry is atomically
quarantined and revalidated before archive publication; a replacement that
reappears at the public name is preserved while the verified legacy archive is
retained for recovery. A post-staging hook then verifies both the pinned
worktree name and staged index deletion immediately before commit. The migration also requires a clean hive-state index,
preventing a scoped runtime commit from absorbing unrelated staged entries. If
the commit fails or Ctrl-C interrupts before it is durable, Hive unstages the
migration first, restores the config, descriptor, and previous runtime, and
returns the original error. Interrupt bookkeeping is masked around each move and
the commit result; once the commit lands, Hive preserves that coherent durable
state rather than rolling back only the working tree. A runtime that cannot be
removed during rollback is left in place while the previous runtime is retained
at a reported backup path, avoiding destructive backup nesting.
Any modified or independently authored descriptor named `bench` still fails the
normal collision guard rather than being mistaken for the legacy workflow.
The upgrade path was live-smoked on the existing hive-bench state checkout on
2026-07-14: the built-in `bench`, sibling `bench-generate`, and explicitly pinned
`coding` tasks all remained resolvable, with all nine pre-migration status rows
still visible and the unrelated dirty-state fingerprint unchanged.

`hive workflow new ID` (see [[commands/workflow]]) scaffolds the minimal `inbox -> work -> done` descriptor plus `work.md` instruction and commits those files to `hive/state`. The only richer shipped scaffold is `--template research`; Architecture and Writing are installed as full reviewed Honeycomb packages so their agent-slot configuration remains operator-owned.

## Managed Honeycomb overlay

`Hive::WorkflowPackage` defines a second, stricter trust boundary without
weakening owner-authored descriptor compatibility:

- `Manifest`, `RegistryManifest`, `CanonicalJSON`, `CanonicalYAML`, `Validator`, and `SecurityScanner` enforce
  canonical metadata, full path/hash coverage, safe package filesystem shapes,
  package-name descriptor binding, redacted diagnostics, and objective
  warning/error rules. Scanner documentation negation is fail-closed: only a
  narrowly recognized prohibition or absence statement that directly governs
  the matched behavior suppresses a finding. Exhortations and double negatives
  such as `do not forget`, `never fail`, `not only`, or `without exception`,
  plus affirmative behavior after a comma or semicolon, remain reportable.
- `RegistryClient` consumes canonical `honeycomb-catalog/v2` flat entries,
  applies listed/latest plus exact soft-hidden/yanked and revoked-blocked
  lifecycle semantics, materializes `packages/NAME/VERSION/` only from the
  exact catalog commit, and rejects tree, release fingerprint, source
  provenance, description, or permission metadata that does not bind to the
  canonical `manifest.yml`. Failed git operations include bounded stderr in the
  typed registry error rather than discarding the underlying cause. Review head
  SHA remains audit data; upstream
  `source_sha` remains source provenance, and neither is the install tree.
- `ManagedStore` places immutable generations plus digest-addressed
  `configurations/<sha256>.json` execution snapshots and selects both through
  an atomic lock-schema-v2 pointer. Each snapshot maps stable actor slots to
  operator-selected agent/model/effort identity, mapping role/contract, profile
  fingerprint, and per-actor policy fingerprint. Snapshot construction rejects
  non-null pins that the selected profile cannot express as native arguments;
  unsupported project defaults remain nil. Strict registry metadata may carry
  sorted `mapping_recommendations` for known executable slots, containing no
  agent/model identity and only an optional portable `low`/`medium`/`high`
  effort. Resolution is field-stable: an explicit install override wins, then a
  compatible installed mapping, then the package recommendation, then the
  project default. Unsupported recommended effort is recorded and disclosed as
  unpinned rather than failing or falling through to another default. Automatic agent suggestions also
  fall back to Claude when the project-default profile cannot enforce a
  non-`yolo` actor scope; explicit mappings are preserved for the existing
  fail-closed runtime admission check. Managed council reviewers and
  revisers launch exclusively from their child-slot snapshot identity, so a
  nil child model/effort cannot leak the parent stage's provider-specific
  defaults. Owner-authored unmanaged councils retain their historical parent
  fallback. `TransactionJournal` plus the workflow mutation lock reconcile an
  interrupted activation/removal before Loader or lifecycle access. Selection
  reads participate in that lock. Invalid selected configurations are skipped
  independently with one named warning, so one missing, malformed, or
  digest-tampered snapshot cannot hide itself or suppress healthy siblings.
  Configuration-only activation against an
  unchanged package generation compares the selected source, manifest, and
  configuration digests before swapping the pointer. Cleanup is serialized
  with managed task creation and stage moves and aborts on unreadable or
  incomplete managed pin provenance. A legacy pin may omit only its
  configuration digest; workflow, source commit, and manifest digest remain a
  required tuple. `workflow list --json` schema v2 reads the selected
  digest-addressed snapshot back through this store to expose per-slot identity
  and redacted optional-input binding/availability. Retained task rows expose
  only a pinned configuration digest, when available, so historical identity
  is not confused with the active selection.
  Activation distinguishes "no baseline check" from an explicit "still
  unselected" baseline; selected baselines compare source commit, manifest
  digest, and configuration digest under the mutation lock. The mutation lock
  classifies only acquisition/open failures as contention; I/O errors raised by
  the protected mutation retain their original type and message.
- `Hive::Workflow#executable_slots` is the single actor-topology boundary for
  configuration snapshots, package validation, and runtime admission. The
  configuration object also owns the redacted mapping/input disclosure used by
  lifecycle commands, so JSON surfaces cannot drift from snapshot semantics.
- `Loader` registers selected managed workflows beside built-ins and authored
  descriptors while rejecting id collisions and reloading when its managed
  fingerprint changes. Task-pinned generations bypass the single-id overlay and
  validate/load directly from `ManagedStore` by id, source commit, manifest
  digest, and configuration digest. Profile fingerprint drift fails closed.
  For a legacy lock-schema-v1 selection, task creation derives the compatibility
  snapshot with the effective project agent profiles and writes that
  digest-addressed snapshot before `meta.yml` can pin it. The snapshot therefore
  remains resolvable after an update replaces the selected pointer with schema
  v2; cleanup retains it while any task references its digest.
- `SemanticDiff` reports prompt/descriptor changes by hash (never prompt text),
  dependency and policy set changes, file inventory changes, and semantic
  escalation reasons.
- `Publisher` rewrites referenced authored instructions into the registry
  layout, packages deterministically, runs the shared validator/runtime
  admission, then delegates to a fork-aware PR client.

Status dispatch adapters share the classifier's derived
`TaskAction::READY_COMMANDS` lookup. The bot exposes every ready command,
including in-process `approve`; the web exposes only commands accepted by the
daemon dispatch-request queue.

Managed locks/generations/configurations are Hive-owned. Lifecycle commands cannot overwrite a
built-in or `<id>.yml` authored descriptor, and task metadata rewrites preserve
all three managed provenance fields.

Honeycomb v2 permission summaries are disclosure/consent data, not executable
policy. Managed execution uses each stage/reviewer/reviser descriptor's exact
`permissions:` block. Explicit `yolo`, scoped shell, and unqualified scoped
file-write actors are portable only after separate high-risk consent; a v2
manifest hiding that actor surface behind a narrower disclosure is rejected.
Bounded actors admit only on profiles that enforce the bound. Strict `x-hive`
metadata declares manifest-hashed executable tools, manifest-hashed prompt
assets exposed as absolute paths in the managed prompt preamble, and optional
environment names with authorized stable slots. Package-declared process
control names are rejected before a value can enter a child environment. Git modes survive
catalog materialization and generation placement. Generation directories and
ordinary files are hardened to 0555 and 0444 before same-parent atomic
publication, trusted executable payloads remain 0555, and reuse repairs mode
tampering after content validation. Snapshots store environment variable names
only and inject a current value only into its executing slot. Each actor spawn
loads that immutable runtime context once for both prompt and permission setup;
preset actor compilation is in-memory and does not create empty policy state.
`gh` and `qmd` remain baseline Hive dependencies. `Publisher` remains on the
legacy submission layout and is not a v2 package authoring path.

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
