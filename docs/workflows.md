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

Published honeycombs are a second, explicitly managed form:

```
.hive-state/workflows/<id>/workflow.yml
.hive-state/workflows/<id>/<package files>
.hive-state/workflows/.honeycomb.lock
```

The nested descriptor keeps publisher-relative instruction paths intact and is
distinguished from the project-authored root `<id>.yml` form. Both forms load
through the same descriptor parser; built-in IDs remain reserved.

## Install A Published Honeycomb

```bash
hive workflow install honeycomb/<name>
hive workflow install honeycomb/<name>@1.2.3
hive workflow list
hive workflow update <name>
hive workflow remove <name>
```

V1 has one source: `github.com/ivankuznetsov/honeycomb`. The unselected form
uses the catalog's latest immutable release. A selector can be an exact SemVer,
a full or unambiguous catalog Git SHA, or a complete recorded package digest.
Mutable aliases and partial versions are rejected.

Before writing the project, Hive fetches the immutable Git commit, accepts only
regular blobs below `workflows/<id>/`, validates `manifest.yml` as an exact
SHA-256 inventory, checks the package digest, parses `workflow.yml`, and derives
its security preview. The manifest itself is not installed. Managed source,
selector intent, immutable SHA/digest, file hashes/modes, and the security
report are recorded in `.honeycomb.lock` for offline ownership checks.

`hive workflow list` reads only local state and an existing catalog snapshot;
it never refreshes the network. Use `--remote` to inspect a freshly fetched
catalog or `--outdated` to refresh and select eligible updates. SHA- and
digest-selected installs are pinned until an explicit selector repins them.
Updates show semantic permission changes, permission escalation, complete
instruction diffs, and descriptor/asset summaries. All selected `--all`
updates are approved and committed as one transaction.

Install, update, and remove prompt by default. Non-TTY callers must pass
`--yes`; missing approval changes neither package files, the lock, nor
`hive/state`. `--force` is only an ownership override for dirty/unmanaged
collisions. It does not approve the preview. A missing or invalid lock permits
only forced best-effort cleanup of a canonical managed root and remains a
non-zero partial result.

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
```

The generated descriptor is valid immediately, and the placeholder
`work.md` is the prompt for the `work` stage. Edit that file to define what the
agent should do.

Then create a task with:

```bash
hive new <project> --workflow my-flow "<your idea>"
```

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
revise agent until quorum or `max_rounds`, then pauses with
`WAITING reason=max_rounds`.

Stage indexes and stage directories are derived from array order. The example
above produces `1-inbox`, `2-work`, and `3-done`. The first stage has no
incoming advance verb; later stages default their incoming advance verb to the
stage name.

## Migration Notes

Existing workflow descriptors continue to load: all new fields are optional.
Workflows that used a prompt-encoded review panel can replace it with
`kind: council`. Workflows that appended a dummy final `kind: terminal` stage
only to satisfy the old parser can drop it and mark the producing agent/council
stage as the final stage, optionally adding `deliverable:` when the output file
differs from `state_file`.

For a ready-to-copy example:

```bash
hive workflow new architecture --template architecture
```

## Trust Boundary

Project workflow descriptors and installed honeycomb descriptors are executable
workflow configuration. An `instruction:` file is injected into the agent
prompt as the stage instruction, not treated as untrusted task data. Honeycomb
installation previews derived permissions, shell-capable stages, shell-shaped
instruction excerpts, and stable high-risk categories; that scanner is an
approval aid, not a shell parser or sandbox. Permission scopes remain tool-level
controls, so run Hive in a sandboxed user/container when isolation from a
descriptor author matters.
