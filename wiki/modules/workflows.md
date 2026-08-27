---
title: Hive::Workflows
type: module
source: lib/hive/workflows.rb, lib/hive/workflow.rb, lib/hive/terminal_outcome.rb, lib/hive/workflows/registry.rb, lib/hive/workflows/coding.rb, lib/hive/workflows/content.rb, lib/hive/workflows/bench.rb, lib/hive/workflows/descriptor_parser.rb, lib/hive/workflows/loader.rb, lib/hive/workflows/project.rb, lib/hive/task_workspace/builder.rb
created: 2026-04-26
updated: 2026-08-25
tags: [module, workflow, result, verbs, selection, human-stage, outcomes, terminal-outcomes, registry, archive, retention]
---

**TLDR**: The coding, content, bench, and project-authored workflows are described as ordered `Hive::Workflow` value objects. Every workflow also resolves one typed `Workflow::Result`: `document` names a task-root primary artifact, while `change` declares the delivery capabilities that make worktree, diff, publication, media, dependency, and supporting-artifact evidence meaningful. Authored descriptors can declare that result explicitly; safe legacy workflows infer it from workspace/handoff, terminal deliverable, completing outcome artifact, or terminal state file. The same result contract drives Web and native semantic task inspection without branching on workflow IDs. Stages continue to carry directory names, state files, incoming advance verbs, runner metadata, permissions, agent/model/effort overrides, council configs, terminal deliverables, and archive visibility policy.

## Descriptor and registry

- `Hive::Workflow` — frozen `Data` value object with `id`, ordered `stages`,
  and normalized `archive_visibility_retention_days` (`Integer` or `:never`).
  `DEFAULT_ARCHIVE_VISIBILITY_RETENTION_DAYS` is the single legacy default
  (`3`). Read-only lookup helpers:
  - `#stage_named(name)` — soft lookup, returns the `Stage` or nil.
  - `#state_file_for(name)` — hard lookup, raises `KeyError` on an unknown name.
  - `#stage_names` / `#stage_dirs` — frozen lists of the descriptor's stage names / `index-name` dirs.
  - `#next_stage_after(name)` — the next `Stage` in descriptor order, or nil for BOTH the terminal stage and an unknown name (consumed by `Approve#resolve_destination` and `Run`'s advance path).
  - `#advance_verb_for(name)` — the incoming advance verb name for a stage, or nil when the stage advances by bare mv (no descriptor verb) OR the name is unknown.
  - `#stage_for_dir(dir)` — soft lookup by `index-name` dir, returns the `Stage` or nil.
  - `#resolve_stage_ref(ref)` — accepts a full dir (`3-plan`) or short name (`plan`) and returns the canonical `Stage#dir` (or nil); used by `Approve` to canonicalize `--to`/`--from`.
  - `#has_stage?(ref)` — predicate wrapper around `#resolve_stage_ref`. An additive affordance (U6.3) for coding-scoped consumers to skip absent-stage behavior; it has no production call sites yet and is currently exercised only by its own unit test.
- Workflow construction maps only `id`, stage name/index/dir/kind, and incoming
  advance-verb presence into `Hive::WorkLedger.validate_descriptor`.
  WorkLedger rejects empty identities/stage lists, gapped ordering, duplicate
  names/dirs, unknown caller-supplied kinds, and a leading advance verb without
  loading condition or coding policy. `Hive::Workflow` preserves its
  `ArgumentError` compatibility surface. YAML slug/filename rules, agent and
  permission lookup, conditions, terminal/deliverable/workspace/handoff rules,
  and built-in kind policy remain in Hive's descriptor adapters.
- `Hive::Workflow::Stage` — frozen stage value object. `#dir` returns `"#{index}-#{name}"`; metadata such as `kind`, `skill`, `instruction`, `permissions`, `status_mode`, `budget_usd`, `timeout_sec`, `capability`, `agent`, `model`, `effort`, `input`, `reviewers`, `council`, and `deliverable` is carried for runner selection, prompt rendering, and status classification. The generic runner path consumes `kind: :agent` (for runner selection), `state_file` (`agent.rb:20`), `skill`, `instruction`, descriptor-level `permissions`, `budget_usd`, `timeout_sec`, and per-stage `agent`/`model`/`effort` overrides. `kind: :council` routes to [[stages/council]] and carries typed `Workflow::Reviewer`, `Workflow::Council`, and optional `Workflow::Revise` values. Coding's action classifier consumes `kind: :execute`, `kind: :review_council`, and `kind: :finalize`; project-authored descriptors still expose only parser-supported user-facing kinds. As of U6 the runner also honors the descriptor's `status_mode`, falling back to `:state_file_marker` only when the stage leaves it unset (`agent.rb:53`); terminal agent/council stages can declare `deliverable` (defaulting to `state_file`) and classify as archived only when that artifact is non-empty.
- `Hive::Workflow::AdvanceVerb` — frozen value object for the verb that advances into a stage, with `force_source` and `interactive` flags defaulting false.
- `Hive::Workflows::Coding::DESCRIPTOR` — the default built-in descriptor (`id: :coding`), matching the current nine-stage pipeline exactly. Its action semantics for coding `:agent`/`:inert` stages live in `Hive::Workflows::Coding::ACTION_DISPATCH`; execute/review/finalize route by their runtime primitive kinds.
- `Hive::Workflows::Content::DESCRIPTOR` — built-in non-coding descriptor (`id: :content`) for `inbox -> research -> outline -> draft -> critique -> done`. `inbox` is inert and captures `idea.md`; every later stage is a generic `kind: :agent` stage with `status_mode: :state_file_marker`, slash-skill metadata, explicit budgets/timeouts, and `done` writing the terminal `article.md`. `Content::BUDGET_USD` is the single frozen source for the shipped per-run caps: research `3.0`, outline `1.5`, draft `3.0`, critique `2.0`, and done `2.0`.
- `Hive::Workflows::Bench::DESCRIPTOR` — built-in hive-bench descriptor (`id: :bench`) for `inbox -> extract -> generate -> judge -> publish -> done`. The four generic agent stages use packaged instructions under `templates/builtins/bench/` and pin their lightweight shell-control work to Codex rather than consuming the Claude account being benchmarked. Extract/publish allow one hour; generate/judge allow seven days so a campaign is not killed by the generic one-hour fallback. Generate starts every unbought matrix cell before it waits, then reaps every child with cell-specific stderr, so independent candidates and tasks use their registered provider allowance concurrently without losing per-cell failure classification. Sealed cells run the Hive controller as root but install an exit trap that restores the bind-mounted target to the host UID/GID, so a later host-side retry can replace and seed the target without colliding with root-owned Git object directories. Generate distinguishes provider-only pending cells from real failures: the former use `Hive::Markers.set` to write `ERROR reason=limits_reached retry_after=...` with canonical recovery identity and attempt metadata, while missing, malformed, contradictory, or non-limit failed cells remain manual `WAITING`. A cell with a clean per-cell result and a preserved non-empty candidate patch is already paid even when its honest generation status is nonterminal; generate normally merges that record into the campaign root and advances it to judge backfill instead of deadlocking before the judge-owned `results.json` exists. Campaigns can opt into `require_successful_execution: true`; those campaigns rerun nonterminal cells instead of treating a preserved patch as bought, and both generate and judge require `generated` or `empty_diff` before any judging spend. Judge applies the same durable cooldown contract after fail-soft rejudge: when the only incomplete evidence is a missing or undersampled configured judge and every exact cell/judge gap has a matching structured quota failure, it writes retryable `ERROR reason=limits_reached` at EOF so the bounded marker scanner can always see it; structural, effort, unmatched, mixed, and non-quota judge failures remain manual `WAITING`. Judge adapters raise `HiveBench::ProviderLimitError` only from trusted failed-process evidence: stderr quota signals or Claude CLI's exact standalone stdout reset banner (optionally preceded by mise's version line), never arbitrary candidate or judge prose about quotas. `HiveBench::JudgeSlate` is the shared source for the pre-deliberation and final result-slate validation, preventing those gates from drifting. A complete configured judge slate is required before `deliberate.rb` can spend or write transcripts. The judge stage also checks the pinned runtime's structured-failure capability before loading the new gate and gives an explicit `hive init . --workflow bench` refresh instruction for older snapshots. Judge completion then requires a numeric 0–10 round-two `final` from every configured deliberation judge; a fail-soft `final: null` remains visible in the transcript, keeps the stage `WAITING`, and is excluded from the retry skip-set so a later run can recover it. `Hive::Workflows::Bench.install_runtime!` snapshots the packaged campaign example, runner image, and harness into `.hive-state/bench-runtime` and commits it on `hive/state`, so `hive init . --workflow bench` needs neither a project-local descriptor nor a separate hive-bench checkout. The runtime is workflow data in the one registered project, not another Hive installation or scheduler. Maintained campaigns are separate `bench` tasks in that project. The packaged candidate registry includes serialized Sol/Terra/Grok comparisons plus Opus-5-plan and Fable-5-plan variants with Sol-high execution and an explicit Sol/Opus review panel. Every candidate declares provider-neutral `models:` routes; the shared Agent CLI Runtime compiles provider argv, and the benchmark keeps no Codex/Grok model wrappers. Generate selects the Codex-0.144+ `sol` image for any GPT-5.6 stage, and that image also carries Grok for mixed cells.
  Deliberation round failures also emit typed cell/judge quota evidence. Matching quota-only missing transcripts and `final: null` verdicts use the durable `limits_reached` cooldown only when every failure emitted for the retried cell is quota-typed; unmatched, mixed, malformed, effort, and non-quota failures remain manual. Incomplete transcripts stay outside the retry skip-set until every configured judge has a numeric final.
- `Hive::Workflows::PatrolFix::DESCRIPTOR` — controller-owned descriptor (`id: :patrol-fix`) for `inbox -> fix -> validate -> review -> publish -> done`. Its active stages declare `kind: controller` and `controller: :patrol_fix`; the resolver uses that capability to select the first-party Patrol Fix runner without matching a workflow id or stage-name list. `done` remains inert. This keeps controller-specific task rebinding and status/action behavior attached to the descriptor while ordinary `agent`, `council`, and inert stages retain the generic runners.
- `Hive::Workflows::Registry.fetch(:coding)` / `.default` — descriptor lookup. Unknown ids raise `Hive::Workflows::UnknownWorkflow`.
- `Hive::Workflows::Registry.all` / `.ids` — live enumeration of registered descriptors/ids (`:coding`, `:content`, `:bench`, plus any scoped test/runtime registrations and the active project's discovered descriptors). Test helpers override this at call time so runtime-registered workflows participate in status scans and slug resolution.
- `Hive::WorkflowSelection.fetch!(name, project_root: Dir.pwd)` — CLI-facing selector validation used by [[commands/init]], [[commands/new]], and project-aware callers. Blank/nil normalizes to `coding`; unknown names raise `Hive::Workflows::UnknownWorkflow` with `valid workflows: ...` from the live registry after project descriptor discovery.

## Project-authored descriptors

Per-project descriptors live under `<hive_state_path>/workflows/*.yml`, defaulting to `.hive-state/workflows/*.yml`. `Hive::Workflows::DescriptorParser` validates YAML into `Hive::Workflow` objects:

- `id` is required, must match the filename stem, and must match `/\A[a-z0-9][a-z0-9-]*\z/`.
- `archive_visibility_retention_days` accepts a positive integer or exact
  lowercase `never`. Key omission normalizes to `3`; key presence is checked
  separately so explicit `null` fails. Floats, booleans, strings (including
  numeric strings), zero, negatives, and alternate sentinel casing fail with
  workflow id, field name, received value, and accepted forms in the error.
- user-facing `kind: agent` maps to `:agent`; `kind: terminal` maps to `:inert`; `kind: council` maps to the generic document council runner.
- stage indexes are derived from array order; non-entry stages default their incoming `advance_verb` to the stage name.
- every user-authored agent stage declares exactly one of `skill:` or `instruction:`.
- agent/council stages may declare `agent`, `model`, and `effort`, which override project stage config. They may also declare `budget_usd` and `timeout_sec` resource defaults; explicitly authored non-null project stage keys take precedence, while values introduced only by the merged config defaults do not shadow the descriptor. Budgets accept positive finite numbers, while timeouts require positive integers. Limits are per spawn rather than aggregate across a council; budgets need a profile-native flag, while timeouts also bound command reviewers/revisers.
- council stages require a `reviewers:` list; each reviewer declares exactly one of `skill`, `instruction`, `prompt`, or `command`, plus optional agent/model/effort/permissions/output basename. The `council:` block carries `quorum`, `max_rounds`, `exit_rule`, `on_max_rounds` (`wait` by default or `complete` for a bounded downstream delivery), `triage_output`, and optional `revise`.
- `instruction:` paths are resolved relative to the descriptor directory and stored on the stage as absolute paths.
- `permissions:` values are validated through `Hive::PermissionScope` at load time and later passed to the generic agent runner as the explicit permission spec. A managed `yolo` actor also receives the owning project root as explicit runner context, alongside its task and immutable package roots, so the declared unbounded actor can inspect or mutate its target when it runs from the task folder. The generic managed prompt names the stage instructions and runtime permission scope as the authority for target edits instead of applying the ordinary task-folder-only constraint, avoiding a contradictory refusal after runtime access has been granted. This does not widen ordinary authored brainstorm/plan stages, whose prompt and runner retain their task-only boundary; portable non-yolo managed actors keep trusted project/worktree roots read-only and remain runtime-enforced.
- the last stage may be inert, agent, council, or human. Active terminal stages
  require `COMPLETE` and their declared non-empty deliverable/artifact before
  `TaskAction` classifies them as archived.
- A final `kind: agent` stage may opt into semantic terminal classification with
  `terminal_outcomes: { complete: [...], blocked: [...] }`. Both lists are
  required, non-empty, unique, disjoint lowercase safe slugs of at most 40
  characters. The stage must declare `deliverable`, and `deliverable` must
  equal `state_file`; council and intermediate stages cannot use this field.
  The field is also incompatible with `workspace` or `handoff`, whose managed
  worktree path uses a separate `Decision:` report and controller receipt.
  `hive workflow validate --json` exposes the normalized object on every stage
  (`null` when absent). See [[stages/agent]] for runtime normalization.
- `workspace: worktree` plus `handoff: draft_pr` is one closed terminal-agent
  contract. Both fields must appear together and both `state_file` and
  `deliverable` must equal task-root `fix-report.md`. Parser and managed-package
  validation reject every partial or alternate shape, including workflows
  constructed directly in Ruby rather than parsed from YAML.

`Hive::Workflows::Loader` discovers project descriptors, and `Hive::Workflows::Project.load!(project_root, config: nil)` is the idempotent boundary call. Callers that already resolved the project config may pass it so descriptor discovery does not parse the same file again; legacy callers keep the self-loading behavior. It swaps the active project overlay in `Hive::Workflows::Registry`, rejects collisions with built-in/runtime ids, and resets the memoized cross-workflow stage unions (`all_stage_dirs`, `all_stage_names`, `all_terminal_stage_dirs`). Descriptor signatures include content, not only mtime/size, so creation, deletion, rename, same-size replacement, and preserved/coarse-mtime replacement are visible on the next load. There is no last-known-good fallback for a currently selected malformed/missing workflow policy. The self-loading path resolves `hive_state_path` from the shared raw project-config reader, installs one fingerprinted overlay, then validates strict root keys against that overlay; it does not call `Config.load` recursively. For command paths that load `Project` without the aggregate `hive/workflows` entrypoint, strict validation derives its stage-name union directly from `Registry.all`, so behavior does not depend on require order. `Config.load` reuses the active overlay when it needs project stage names. `Task`, `WorkflowSelection`, `init`, `new`, `status`, `drop`, and stage-filtered resolver paths call it before resolving workflow ids or stage refs.

Archive visibility resolves the same descriptor order on every refresh:
explicit task `workflow:` pin, project `default_workflow`, then `coding`.
Applying a managed workflow configuration preserves the source descriptor's
retention value. Hive's built-in `coding`, `content`, and `bench` descriptors
and both local scaffolds explicitly declare `3`; legacy and externally managed
descriptors may omit it and receive the same value.

## Workflow result contract

`Hive::Workflow::Result` is the workflow-owned description of what the task is
trying to deliver. It is independent of stage names and Web panels:

- `kind: document` requires one safe bare `primary_artifact` filename inside
  the task folder. A declared terminal `deliverable` must match it.
- `kind: change` has no primary-artifact filename. It describes a repository
  change whose applicable evidence comes from capabilities.
- `capabilities` is a unique subset of `worktree`, `diff`, `publication`,
  `media`, `dependencies`, and `supporting_artifacts`. A workflow using
  `workspace: worktree` and `handoff: draft_pr` must declare the corresponding
  change capabilities; contradictory document declarations fail at load time.
- `provenance` records whether the result was declared or safely inferred. It
  is descriptor/runtime context, not proof that the result exists.

Project-authored YAML accepts a closed top-level shape:

```yaml
result:
  kind: document
  primary_artifact: architecture.md
  capabilities: [supporting_artifacts]
```

Older descriptors remain compatible. Inference chooses, in order, a
worktree/draft-PR change result, terminal `deliverable`, a completing human
outcome artifact, then the terminal `state_file`. The inferred document gets
supporting-artifact capability only; it does not acquire coding-only worktree
or publication expectations. Built-in coding declares a change result with
all delivery capabilities, while built-in content declares `article.md` as its
document result.

`Hive::TaskWorkspace::Builder#semantic` consumes this normalized value. It
opens the declared primary artifact when present, falls back to the current
stage artifact while work is in progress, warns when a completed task is
missing its declared deliverable, and emits only applicable evidence. Web and
`hive task TARGET --project NAME --json` therefore use the same workflow
meaning without `coding`, `architecture`, or `writing` conditionals in the
view.

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

The packaged runtime includes the single-family Ox Alpha routes used by the
maintained comparison: Pi at explicit `high` and `max` reasoning, plus OpenCode
at `high`. All three routes keep benchmark plan review disabled under the
process-local grant. OpenCode's provider events remain redacted in Hive logs;
the harness recovers its normalized input, output, cache-read, and cache-write
totals from the cell-local Hive usage database when no stream tokens exist.
The runner image carries the pinned OpenCode CLI and Compound Engineering
package, while Pi receives the minimal pinned OpenRouter model catalog.
OpenRouter disclosed Ox Alpha as Z.ai GLM 5.3 Flash and retired the stealth
inference route on 2026-08-26. The maintained profiles therefore keep their Ox
Alpha candidate ids for lineage while routing the revealed model through
`z-ai/glm-5.3-flash`; model-version receipts name GLM 5.3 Flash explicitly.
The generated OpenCode profile uses only Hive-supported override keys; OS and
network containment belong to the disposable runner rather than the retired
`agents.opencode.isolation` setting. Its scoped permission document grants the
qualified `Bash(*)` tool so OpenCode and Pi can both run repository diagnostics
and tests.
Candidate source preparation fetches only the exact historical base at depth
one. This keeps descendant/reference objects, source refs, tags, and reflogs out
of the candidate repository instead of relying on `remote remove` to hide them.
Published local campaigns can also require provider-only egress: generation
attaches to a named internal Docker network and receives a credential-free
CONNECT-proxy URL; partial or missing strict configuration fails before model
spend. The base-only and egress modes are bound into generation identity, so an
older unrestricted artifact cannot be silently reused as strict evidence.
Campaigns can additionally require `isolation.sealed_agent_runtime: true`.
The runner image is labelled with the exact Hive build SHA and splits Ruby gems
into a root-only Hive control bundle plus a candidate bundle with `hive-cli`
removed. The container controller runs as root, but the Pi/OpenCode launchers
chown `/work`, drop the model process to uid 1000, remove its Linux capabilities,
and reset its gem path. The driver omits all host Hive source/gem mounts and
refuses model spend when the image label does not match the active immutable
dogfood deployment. Runtime visibility joins base history and egress in the
generation identity, so unsealed artifacts cannot satisfy a sealed campaign.
When the control plane is invoked through the dogfood wrapper, the packaged
driver resolves the exact immutable deployment named by
`HIVE_RUNTIME_DEPLOYMENT_ID` and verifies its full commit against
`HIVE_RUNTIME_BUILD_SHA`. It does not treat the stable wrapper as a source
runtime or follow the mutable `dogfood-current` pointer after the task starts;
an explicit `HB_HIVE_BIN` override still takes precedence and fails closed.
Generate and judge quota markers likewise load `Hive::Markers` (and the judge
cooldown helper) from the campaign's immutable `source/lib`, so a scrubbed
stage-agent shell cannot silently fall back to an older installed hive-cli gem
with a different marker API.


`hive workflow new ID` (see [[commands/workflow]]) scaffolds the minimal `inbox -> work -> done` descriptor plus `work.md` instruction and commits those initial files to `hive/state`. After editing, the natural-language creator validates and invokes `hive workflow commit ID`, which commits the populated descriptor/instruction directory under the shared state commit lock before it reports success or creates a task. The only richer shipped scaffold is `--template research`; Architecture and Writing are installed as full reviewed Honeycomb packages so their agent-slot configuration remains operator-owned.

## Managed workflow packages

Reviewed Honeycomb packages deliberately use a stricter boundary than the
owner-authored descriptors documented here. [[modules/workflow_package]] is the
authoritative page for catalog and package identity, immutable generations and
configuration snapshots, task provenance, runtime admission, permission
consent, and publication recovery. This page retains only descriptor, registry,
verb, and runner semantics.

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

The descriptor reads every Content cap from the frozen
`Hive::Workflows::Content::BUDGET_USD` map. These are fixed shipped defaults,
not dynamically scaled values: research `3.0`, outline `1.5`, draft `3.0`,
critique `2.0`, and done `2.0`. A project-authored explicit non-null stage
override still takes precedence through the generic workflow resource
resolution described above.

Hermetic coverage lives in `test/unit/workflows/content_test.rb`,
`test/integration/content_workflow_stage_test.rb`, and
`test/integration/content_workflow_e2e_test.rb`.

## Patrol Fix workflow projection

Patrol Fix uses the normal task workflow concurrency for
Inbox/Fix/Validate/Review/Publish/Done after discovery admission. Discovery
allowances stay outside workflow capacity. The common daemon-owned operational
projection reports the active stage, parked/provider state, rework and
rejection outcomes, successor linkage, and exact PR-created/open fields without
giving any status adapter a second task-state interpretation or mutation path.
The controller descriptor is also the shared capability check used by command,
action, and stage-wrapper paths, so those paths do not carry a parallel
`patrol_fix_id?` predicate. Review and publication share one exact worktree
snapshot helper for custody, HEAD, cleanliness, bounded diff, and digest
validation; Inbox and Review output readers share the same strict JSON reader
while retaining their route and schema ownership. On the first Fix generation,
the controller fetches the configured default branch from `origin` and records
that exact remote OID as the worktree base. The local `HEAD` observed by Inbox
is decision evidence only. There is no local-base fallback, while rework keeps
the already-owned checkout and base. A same-generation retry also reuses that
custody without refetching a moving remote branch.

Publish secret-policy failures are projected as a distinct operator park, not
as a recoverable failed attempt. Their sanitized append-only receipt is the
freshness authority for `patrol_fix.rework_publication`, which advances a new
generation to the earliest controller stage able to change the blocked bytes.
The ordinary daemon never dispatches that action and `workflow.retry` cannot
clear it.

## Durable human stages

`Hive::Workflow::Stage` accepts `kind: :human` plus immutable named
`outcomes`. The owner-authored parser exposes only closed directional actions:
an outcome must either complete the workflow or target another stage, and a
completing outcome may name an artifact. Unsafe outcome names, unknown keys,
missing/duplicate actions, unknown targets, and agent-only settings fail while
the descriptor is loaded.

A human stage has no runner. Entering it leaves the state file `WAITING`, and
status exposes `NEEDS_INPUT` with the descriptor's allowed outcomes.
`Hive::Commands::Decide` writes a durable decision record with outcome, note,
artifact/target, and timestamp. A completing decision verifies its declared
artifact, stamps `meta.yml completed_at` from the same clock, and exposes the
task through the shared archive/retention path. Decision-state reads refuse
symlinks and verify the opened inode. State, metadata, and moves roll back
together when a commit fails or is interrupted. A returning decision moves the
same task under the task/state locks and resets the target state file to
`WAITING`, preventing a stale completion marker from immediately advancing it
again.

The accepted editorial graph is exactly
`research -> draft -> approval`: `approve` completes with non-empty
`draft.md` recorded as publish-ready, while `reject` returns to `draft`.
There is no publish stage or executable outcome action.

## Backlinks

- [[commands/run]] — workflow verb dispatch via `Hive::Commands::StageAction`
- [[modules/task_action]] — uses VERBS to build per-state next-action commands
- [[modules/stages]] — the canonical stage list this module references
- [[modules/task]] — task stage validation and state-file lookup derived from the descriptor-backed constants
- [[modules/workflow_package]] — reviewed Honeycomb trust, storage, policy, and publication boundary
