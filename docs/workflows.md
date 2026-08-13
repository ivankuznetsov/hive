# Project Workflows

Hive ships with built-in `coding`, `content`, and `bench` workflows. A project can also
define owner-authored workflows under its Hive state tree:

```
.hive-state/workflows/<id>.yml
.hive-state/workflows/<id>/<stage>.md
```

`hive init` still chooses the project default workflow, and `hive new
PROJECT --workflow <id> "..."` pins a single task to a workflow. Project
workflow descriptors are discovered at runtime by `hive new`, `hive init`,
`hive status`, `hive run`, `hive approve`, and the daemon path that uses those
commands.

## Run The Built-In Benchmark Workflow

The `bench` workflow drives a reproducible hive-bench campaign through
`inbox -> extract -> generate -> judge -> publish -> done`. Its descriptor,
stage instructions, campaign example, and runtime harness ship with Hive:

```bash
hive init /path/to/benchmark-project --workflow bench
hive new benchmark-project "benchmark campaign"
```

Hive snapshots the runtime under `.hive-state/bench-runtime` on the durable
state branch. Copy its `campaign.yml.example` into the printed task folder as
the tracked `campaign.yml`; the daemon then advances the task through the
packaged stages. The control plane uses Codex and allows up to seven
days for the serialized generate/judge stages; the candidate and judge models
inside the campaign remain governed solely by `campaign.yml`. See the
hive-bench README for the campaign schema, credentials, and public submission
process. If every unfinished generation cell is parked only by provider quota,
the stage writes a cooldown-aware `limits_reached` marker so the daemon retries
after reset; malformed/missing/non-limit failures remain manual `WAITING`
states.

## Create A Workflow From Natural Language

The canonical Hive agent skill accepts ordinary-language workflow creation
requests. In OpenClaw and Claude invoke it as `/hive`; Codex uses `$hive` and
Pi uses `/skill:hive`. For example:

```text
/hive create a three-stage editorial workflow that researches, drafts, and requires approval before publishing
```

The creator checks the installed Hive version, project settings, templates,
reserved IDs, and existing workflow IDs before it writes anything. In an
initialized project it scaffolds only new paths with `hive workflow new`, edits
those generated files, validates them, and commits the populated descriptor and
instruction directory to `hive/state` before reporting success:

```bash
hive workflow validate editorial --json
hive workflow commit editorial
```

In a fresh project it first renders the no-write
`hive init --new-workflow editorial --minimal --preview --json` plan and waits
for one explicit confirmation before running the matching command without
`--preview`. The minimal profile creates the core Hive project, state worktree,
registration, and required wiki/context integration while leaving optional
patrol, auto-fix, daemon dispatch/autostart, babysitter, and timer setup off. It
never selects a starter template or adds `--force`.

The accepted editorial result has exactly three stages:

```yaml
id: editorial
stages:
  - name: research
    kind: agent
    state_file: research.md
    instruction: ./editorial/research.md
    permissions: yolo
  - name: draft
    kind: agent
    state_file: draft.md
    instruction: ./editorial/draft.md
    permissions: yolo
  - name: approval
    kind: human
    state_file: approval.md
    input: draft.md
    outcomes:
      approve:
        complete: true
        artifact: draft.md
      reject:
        to: draft
```

The stage and model choices inherit project defaults. The creator reports that
inheritance, sequential transitions, local `yolo` permissions, artifact names,
the neutral scaffold/template choice, every created file, and the validation
result. No task is created by workflow creation alone. Its completion summary
includes the exact opt-in command:

```bash
hive new '<project>' --workflow 'editorial' '<your request>'
```

If the original request explicitly asks to create or run a task, the creator
uses `hive new --idempotency-key KEY --json`, so a retry finds the same task
even after it moves stages. It queries `hive status --operational --json` after
creation or an explicitly requested first run. It derives that key
deterministically from the real project path, normalized workflow ID, and
canonicalized request text. Every dynamic argument uses POSIX shell escaping,
so quotes, substitutions, variables, glob characters, and newlines remain
literal request bytes.

When the task reaches approval, the only transitions are:

```bash
hive decide <task> approve --from approval --decision-id <decision-id>
hive decide <task> reject --from approval --decision-id <decision-id> --note "revise the conclusion"
```

The waiting `hive run --json` response supplies the visit-specific decision
ID. Approve requires a non-empty, regular task-local `draft.md` (symlinks are
refused), records it as publish-ready, and completes the task. Reject records the decision, returns the same task to
`draft`, and resets that stage to `WAITING`. Neither outcome publishes, deploys,
sends, or otherwise acts outside Hive; an external destination and separate
authorization are always required.

The creator is create-only. Reserved or colliding IDs stop before mutation and
return an available alternative. Editing or repairing an existing workflow is
outside this contract.

## Create A Blank Workflow

```bash
hive workflow new my-flow
```

This writes a minimal `inbox -> work -> done` workflow:

```
.hive-state/workflows/my-flow.yml
.hive-state/workflows/my-flow/work.md
.hive-state/workflows/my-flow/README.md
.hive-state/workflows/my-flow/honeycomb.yml
```

The generated descriptor is valid immediately, and the placeholder
`work.md` is the prompt for the `work` stage. Edit that file to define what the
agent should do. New scaffolds explicitly set
`archive_visibility_retention_days: 3`. Then validate the production-loaded
descriptor:

```bash
hive workflow validate my-flow --json
```

`README.md` and `honeycomb.yml` are publish-preflight inputs. Complete the
authored description, author, SPDX license, minimum Hive version, immutable
source URL/revision, and optional closed asset list. Every README scaffold has
required `Behavior`, `Prerequisites`, `Inputs`, `Outputs`, `Permissions and
Risks`, and `Recovery` sections; placeholders are rejected. These files do not
change how an owner-authored workflow runs locally.

Then create a task with:

```bash
hive new <project> --workflow my-flow "<your idea>"
```

## Reviewed Honeycomb Packages

Managed Honeycomb workflows are a separate, reviewed package origin and a
one-workflow compatibility projection of Hive's generalized module lifecycle.
Use `hive module` for packages that add hooks, schedules, events, typed
settings, or grants. Existing catalog entries and installed locks require no
republish or manual migration.

Typical operator commands are:

```bash
hive workflow install honeycomb/architecture --yes
hive workflow install honeycomb/writing --yes
hive workflow install honeycomb/seo-content --yes --allow-escalation
hive workflow list --json
hive workflow update architecture --dry-run --json
hive workflow update architecture --yes
hive workflow remove architecture --yes
hive workflow publish my-flow --version 1.0.0 --dry-run --json
hive workflow publish my-flow --version 1.0.0 \
  --expected-release-digest <confirmed-release-digest> --json
```

Architecture and Writing previously existed as lightweight `workflow new`
scaffold templates. Their full reviewed packages now own those names;
`--template architecture` and `--template writing` return the corresponding
install command. The owner-authored samples that remain are `blank` and
`research`.

The command contract—including accepted source forms, mapping/input flags,
consent UX, dry-run behavior, statuses, and JSON fields—is maintained in the
[`hive workflow` command page](../wiki/commands/workflow.md). The managed
[package module page](../wiki/modules/workflow_package.md) is authoritative for
catalog/package trust, immutable identity, task pins, disclosure versus exact
runtime enforcement, high-risk consent classification, and publication
recovery. The generalized native-module lifecycle is documented in
[modules.md](modules.md).

Hive Web exposes install, update, and remove under **Workflows** as a two-step
review: the command's real dry-run disclosure followed by a short-lived receipt
bound to that reviewed state. Publication remains a CLI-only author workflow.

## Descriptor Schema

```yaml
id: my-flow
archive_visibility_retention_days: 3
stages:
  - name: inbox
    kind: terminal
    state_file: idea.md
  - name: work
    kind: agent
    state_file: work.md
    instruction: ./my-flow/work.md
    agent: claude
    model: opus
    effort: high
    budget_usd: 12.50
    timeout_sec: 7200
    permissions: read-only
  - name: done
    kind: terminal
    state_file: done.md
```

Rules:

- `id` must match the filename stem and `/\A[a-z0-9][a-z0-9-]*\z/`.
- `archive_visibility_retention_days` accepts only a positive YAML integer or
  the exact lowercase sentinel `never`. Each integer is a number of full
  24-hour periods; a task remains visible at the exact boundary and hides only
  after it. Omission defaults to `3` for legacy descriptors, while an explicit
  `null`, zero, negative, float, numeric string, boolean, or alternate spelling
  is invalid. Validation names the workflow, field, received value, and
  accepted forms.
- Retention changes ordinary visibility only. `never` keeps completed tasks in
  ordinary views indefinitely; every policy leaves the dedicated archive
  complete and never deletes, moves, reopens, or otherwise mutates a task.
- `kind: terminal` creates an inert stage; it does not spawn an agent.
- `kind: agent` spawns the generic stage runner.
- `kind: council` runs a document review council over an input artifact.
- `kind: human` persists `WAITING` and exposes only descriptor-declared
  outcomes through
  `hive decide TARGET OUTCOME --from STAGE --decision-id DECISION_ID`.
- Every agent stage must declare exactly one of `skill:` or `instruction:`.
- `agent:`, `model:`, and `effort:` are optional on `kind: agent` and
  `kind: council`. Descriptor `agent` overrides the project stage block;
  descriptor `model` / `effort` supply the per-stage identity values and reach
  profiles that support native identity flags. Project stage blocks do not
  override `model` / `effort`.
- `budget_usd:` and `timeout_sec:` provide optional resource defaults for
  `kind: agent` and `kind: council`; explicitly authored, non-null project stage
  config takes precedence. Values inherited from Hive's merged config defaults do not
  shadow descriptor defaults. `budget_usd` must be a positive finite number and
  `timeout_sec` a positive integer.
  - Limits apply to each agent spawn, not to the aggregate cost or duration of
    a multi-reviewer, multi-round council.
  - `budget_usd` is enforced only when the selected agent profile exposes a
    native budget flag. Hive writes `config-warnings.log` when a profile cannot
    enforce it; `timeout_sec` remains enforced for every agent spawn.
  - Council command reviewers and command revisers also use `timeout_sec`; Hive
    terminates their process group when the limit expires.
- A human stage declares `input:` plus one or more named `outcomes:`. Every
  outcome has exactly one action: `complete: true` with a required non-empty
  `artifact:` basename, or `to: <stage>`. Human stages cannot declare agent,
  model, permission, runner, reviewer, or executable command settings. A
  completing outcome writes a durable decision and `completed_at`, then enters
  the same archive visibility/retention path as other completed workflows.
- `skill:`, `instruction:`, `agent:`, `model:`, `effort:`, `budget_usd:`,
  `timeout_sec:`, `permissions:`, `input:`, `reviewers:`, `council:`, and
  `deliverable:` are rejected on `kind: terminal` stages.
- `instruction:` is resolved relative to the descriptor file and must point to a readable file (any extension; `.md` is conventional but not required).
- `permissions:` is optional and uses the same syntax as [permissions.md](permissions.md).
- `workspace: worktree` and `handoff: draft_pr` are one closed v1 pair on the
  final `kind: agent` stage. Both `state_file:` and `deliverable:` must be the
  canonical task-root `fix-report.md`; worktree-only, handoff-only, alternate
  report names, inert/council use, and nonterminal use are rejected. The pair
  creates a controller-owned exact-origin worktree and controller-owned draft
  PR delivery without embedding an agent, model, or effort choice.
- The last stage may be `kind: terminal`, `kind: agent`, `kind: council`, or `kind: human`.
  A terminal agent/council stage is archived only when it has a terminal
  `COMPLETE` marker and a non-empty deliverable. `deliverable:` defaults to the
  stage's `state_file`. A terminal human stage is archived only after a named
  completing outcome verifies its declared non-empty artifact.

Council stages declare reviewers and a council policy:

```yaml
- name: review
  kind: council
  state_file: review.md
  input: draft.md
  council:
    quorum: 2
    max_rounds: 3
    exit_rule: consensus # consensus | human
    on_max_rounds: wait   # wait | complete
    triage_output: reviews/triage.md
    revise:
      agent: claude
      instruction: ./my-flow/revise.md
  reviewers:
    - name: claude-doc
      agent: claude
      prompt: Review for clarity, risk, and missing decisions.
      output_basename: claude-doc
    - name: codex-doc
      agent: codex
      prompt: Review for implementation risk and testability.
```

Each reviewer declares exactly one of `skill:`, `instruction:`, `prompt:`, or
`command:` and writes `reviews/<output_basename>-NN.md`. Triage writes
`reviews/triage-NN.md` plus the configured latest triage file, recording
verdicts, accepted findings, rejected findings, required edits, open
disagreements, and readiness. If quorum is not met, `exit_rule: human` pauses
with `WAITING reason=needs_revision`; `exit_rule: consensus` runs the optional
revise agent until quorum or `max_rounds`. The default
`on_max_rounds: wait` pauses with `WAITING reason=max_rounds`; bounded editorial
workflows may opt into `on_max_rounds: complete`, which writes
`COMPLETE reason=max_rounds` so a downstream delivery stage can emit an
explicit non-publishable capped outcome.

Stage indexes and stage directories are derived from array order. The example
above produces `1-inbox`, `2-work`, and `3-done`. The first stage has no
incoming advance verb; later stages default their incoming advance verb to the
stage name.

Project configuration has a strict top-level vocabulary. Exact stage names
from built-in and active project workflow descriptors are the sanctioned
dynamic extension point for per-stage agent and permission overrides. Resource
limits remain in the existing `budget_usd` and `timeout_sec` maps, keyed by the
exact stage name:

```yaml
work:
  agent: codex
  permissions: read-only
budget_usd:
  work: 12.50
timeout_sec:
  work: 3600
```

Put `model` and `effort` on the workflow stage descriptor (or use the selected
agent profile's project-global configuration); a project `work.model` or
`work.effort` value is not a runtime override.

The built-in top-level `models:` map is deliberately closed and does not accept
custom stage names. A copyable custom-workflow equivalent is:

```yaml
id: analysis
stages:
  - name: inbox
    kind: terminal
    state_file: idea.md
  - name: investigate
    kind: agent
    state_file: report.md
    instruction: ./analysis/investigate.md
    agent: codex
    model: gpt-5.6-sol
    effort: xhigh
  - name: done
    kind: terminal
    state_file: done.md
```

Here `investigate.model` and `investigate.effort` remain descriptor-owned.
Adding `models.investigate` to project config is an error, and built-in family
inheritance does not cross into this descriptor. A descriptor deliberately
named for one of the closed built-in identities is the exception: the generic
agent/council runner recognizes that identity and applies its `models:` overlay
at the normal profile launch seam. This keeps arbitrary names open for custom
workflows without making the routing vocabulary open-ended.

Hive rejects arbitrary top-level names, including stage-name lookalikes. The
stage must be present in a registered descriptor before its override is valid.
Project review adapters are a separate configuration surface and belong under
`review.reviewers`; the `reviewers:` list shown inside a `kind: council` stage
above is nested descriptor data, not a project-config root key.

## Migration Notes

The automatic implementation-owner policy applies only to the built-in coding
workflow's `execute`, `open_pr`, `review.fix`, and `review.ci` boundaries.
Descriptor-backed agent and council stages continue to resolve their own
optional `agent`, `model`, and `effort` fields, and council reviewers are never
inherited from the coding execute owner. If such a descriptor uses a recognized
built-in routing name, its model/effort fields become that call's current
fallback beneath the exact/coarse `models:` overlay.

Existing workflow descriptors continue to load: an omitted
`archive_visibility_retention_days` resolves to `3`. Hive-owned `coding`,
`content`, and `bench` descriptors and newly generated `blank`/`research`
descriptors declare `3` explicitly. The Honeycomb-owned Writing package should
declare the field in its own repository; installed legacy generations remain
correct through the omission default.
Stages that omit both `workspace:` and `handoff:` retain task-folder execution
and their existing completion behavior. The fields may not be enabled
independently.
Workflows that used a prompt-encoded review panel can replace it with
`kind: council`. Workflows that appended a dummy final `kind: terminal` stage
only to satisfy the old parser can drop it and mark the producing agent/council
stage as the final stage, optionally adding `deliverable:` when the output file
differs from `state_file`.

For a ready-to-copy example:

```bash
hive workflow install honeycomb/architecture --yes
hive new <project> --workflow architecture "Plan the system..."
```

## Trust Boundary

Project workflow descriptors are trusted project-owner configuration. An
`instruction:` file is injected into the agent prompt as the stage instruction,
not treated as untrusted task data. Managed Honeycomb instructions instead pass
package admission and run with a task-pinned exact permission scope plus a
sanitized child environment. V2 actor presets do not disable inherited Claude
settings, hooks, plugins, or MCP configuration. Both permission systems are
tool-level controls, not a universal OS sandbox; run Hive in a sandboxed
user/container when host and configuration-source isolation matter.
