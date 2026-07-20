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
agent should do.

`README.md` and `honeycomb.yml` are publish-preflight inputs. The scaffolded
summary and author are placeholders; edit them before running `workflow
publish`. They do not change how an owner-authored workflow runs locally.

Then create a task with:

```bash
hive new <project> --workflow my-flow "<your idea>"
```

## Reviewed Honeycomb Packages

Honeycomb packages are a separate, untrusted-by-default workflow origin. Hive
consumes the official flat `honeycomb-catalog/v2` snapshot and accepts only
`honeycomb/<name>[@<listed-version-or-full-source-revision>]`. Bare names select
the highest listed/discoverable version; exact soft-hidden or yanked versions
remain available; revoked versions fail closed with their advisory IDs.
Branches, tags, abbreviated revisions, arbitrary repositories, and unlisted
versions are rejected.

```bash
hive workflow install honeycomb/architecture --yes
hive workflow install honeycomb/writing --yes
hive workflow install honeycomb/seo-content --yes --allow-escalation
hive workflow list
hive workflow update architecture --dry-run
hive workflow update architecture --yes
hive workflow remove architecture --yes
hive workflow publish my-flow --version 1.0.0
```

Architecture and Writing previously existed as lightweight `workflow new`
scaffold templates. Their full reviewed packages now own those names in
Honeycomb; `--template architecture` and `--template writing` return the exact
install command instead of creating a reduced local copy. The owner-authored
samples that remain in Hive are `blank` and `research`.

Install clones one exact catalog snapshot, materializes
`packages/<name>/<version>/` from that catalog commit (not from the review-head
audit identity or upstream `source_sha`), and verifies canonical `manifest.yml`
bytes, `release_sha256`, the complete Git tree, every payload hash, catalog to
manifest metadata binding, static security findings, and runner capabilities
before asking for confirmation. A managed selection is an atomic lock over an
immutable catalog-commit generation:

Before consent, Hive shows an agent mapping for every stage, council reviewer,
and reviser. Suggestions start from the project choices made by `hive init`.
When one of those agents cannot enforce an actor's non-`yolo` tool scope, Hive
suggests Claude for that slot instead so accepting all defaults remains
runnable. An explicit mapping is never rewritten: an incompatible explicit
choice fails runtime admission before project state changes.

```text
.hive-state/workflows/<name>/honeycomb.lock.json
.hive-state/workflows/<name>/versions/<catalog-commit>/
```

New tasks pin the catalog commit and release digest in `meta.yml`. Updating or
removing the project selection therefore affects only new tasks; generations
still referenced by existing tasks remain verifiable and runnable. Tampering
is an integrity error, never an implicit local override.

Lifecycle mutations recheck the selected source commit and manifest digest
inside the workflow mutation lock. A first install likewise verifies that no
selection appeared after validation. If another operator changes the selection
between preview and apply, Hive stops with a retryable conflict instead of
installing, updating, or removing a generation the caller did not review.

`workflow update --dry-run` validates and returns descriptor, instruction,
manifest, dependency, permission, command, domain, and file changes without
writing project state. An applied update always needs ordinary confirmation.
Capability additions, removed deny rules, dependency additions, or
incomparable dependency changes additionally require a separate
`--allow-escalation`; neither consent flag implies the other.

`workflow list --json` schema v2 keeps origin, selection, integrity, and
catalog visibility as orthogonal fields. A verified selected row also reports
its active configuration digest, every stable-slot agent/model/effort mapping,
and optional-input environment binding plus current availability. Values are
never read into the document. A task-retained row carries its configuration
digest when the task metadata has one, but does not present that historical
snapshot as the active mapping. Owner-authored and built-in rows retain their
generation-free shape. `workflow remove` operates only on Hive-managed locks
and never deletes task-pinned generations or owner-authored/built-in workflows.
List and remove work offline; catalog visibility is reported as
`unknown_offline` until a trusted refresh is available.

Hivebox exposes the same project-scoped lifecycle under **Workflows**. It lists
built-in, authored, selected, and retained generations; scaffolds project
workflows; and makes install/update/remove a two-step review. The first step is
the command's real dry-run disclosure. The second uses a 15-minute signed
receipt bound to the reviewed package, configuration, and selected baseline;
security-expanding updates require their own checkbox in addition to ordinary
update consent. The current legacy `workflow publish` output is shown as a known
limitation rather than an action that would open an unusable v2 registry PR.

Honeycomb v2 manifests carry coarse disclosure for review and consent, while
each executable stage, reviewer, and reviser declares its exact runtime
`permissions:`. Install rejects a manifest that understates those actor
permissions. High-risk actors require a separate `--allow-escalation` consent.
The strict `x-hive` extension names manifest-hashed executable tools, optional
prompt assets, and optional environment inputs authorized for stable actor
slots. Input values remain in the operator environment: configuration stores
only the binding name, injects a current value only into its authorized child,
and rejects package-declared process-control names such as `PATH`, `HOME`,
`RUBYOPT`, and `LD_PRELOAD`.

`workflow publish` still emits the legacy `workflows/<name>/manifest.json`
submission shape. It remains `pending_review`, not listed, and does not yet
produce the current `packages/<name>/<version>/manifest.yml` registry contract.

## Descriptor Schema

```yaml
id: my-flow
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
- `kind: terminal` creates an inert stage; it does not spawn an agent.
- `kind: agent` spawns the generic stage runner.
- `kind: council` runs a document review council over an input artifact.
- Every agent stage must declare exactly one of `skill:` or `instruction:`.
- `agent:`, `model:`, and `effort:` are optional on `kind: agent` and
  `kind: council`. Descriptor values override project stage config; Claude
  stages receive `model` / `effort` as CLI flags.
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
- `skill:`, `instruction:`, `agent:`, `model:`, `effort:`, `budget_usd:`,
  `timeout_sec:`, `permissions:`, `input:`, `reviewers:`, `council:`, and
  `deliverable:` are rejected on `kind: terminal` stages.
- `instruction:` is resolved relative to the descriptor file and must point to a readable file (any extension; `.md` is conventional but not required).
- `permissions:` is optional and uses the same syntax as [permissions.md](permissions.md).
- The last stage may be `kind: terminal`, `kind: agent`, or `kind: council`.
  A terminal agent/council stage is archived only when it has a terminal
  `COMPLETE` marker and a non-empty deliverable. `deliverable:` defaults to the
  stage's `state_file`.

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

## Migration Notes

The automatic implementation-owner policy applies only to the built-in coding workflow's `execute`, `open_pr`, `review.fix`, and `review.ci` boundaries. Descriptor-backed agent and council stages continue to resolve their own optional `agent`, `model`, and `effort` fields, and council reviewers are never inherited from the coding execute owner.

Existing workflow descriptors continue to load: all new fields are optional.
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
