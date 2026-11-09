---
title: Skill and workflow proposal tracking
type: module
source: lib/hive/proposals.rb, lib/hive/proposals/, schemas/hive-proposal-*.v1.json
created: 2026-08-30
updated: 2026-11-09
tags: [proposals, skills, workflows, evidence, lifecycle, history]
---

**TLDR**: `Hive::Proposals` is a tracking-only, project-level history for skill
and workflow candidate revisions. Durable proposal-bound task attempts may open
candidates and append evaluations. Configured lifecycle authorities may append
decisions, supersession, and rollback evidence. Nothing in this module installs,
publishes, activates, removes, or reverts an active skill or workflow.

## Canonical state

Producer failure rollback preserves the task journal and proposal source files.
It does not read or restore the removed task projection snapshots/checkpoints.
Durable attempt bindings come from the SQLite attempt repository.

The canonical namespace is the project `hive/state` worktree:

```text
proposals/v1/
├── inbox/<source-event-id>.json
├── inbox/index.json
├── inbox/consumed/<source-event-id>.json
├── inbox/quarantine/<source-event-id>.json
├── records/<proposal-id>.json
└── events/<proposal-id>/<20-digit-version>-<event-id>.json
```

Each candidate revision receives a permanent UUID-backed `prp-*` ID. The record
is immutable. Evaluations, the single accepted/rejected decision, optional
supersession, and optional rollback are independent immutable `pev-*` event
files. New or retried candidate revisions use new proposal IDs; `retries` and
authority-approved `supersedes` facts express lineage.

`Store` reads every bounded regular file independently with no-follow semantics.
Invalid JSON, unsafe files, unknown versions, duplicate identity, broken event
versions, and inconsistent histories become safe logical quarantine diagnostics;
valid neighbors remain queryable and compilable. Malformed source-quarantine
reason values are rejected as isolated diagnostics instead of aborting discovery.
Malformed event filenames reserve their numeric version so recovery never
overwrites unknown bytes, and any reserved slot without a valid canonical event
quarantines that proposal projection rather than exposing an unknowable lifecycle head. Both
the canonical store and source inbox use bounded lock acquisition.

## Durable source admission

`Producer` is the only submission/evaluation persistence boundary. It reconstructs
the proposal subject, actor, optional evaluator, configuration fingerprint, and
evidence policy from the durable `Attempts::Record`; CLI text and artifact fields
cannot replace those bindings. `Producer.for_task` reuses a binding only inside
the authenticated worker (`Attempts::Context`) of the task's live admitted
attempt, so a finished earlier proposal attempt can never capture a later
command's subject. Otherwise the source-command controller creates a fresh
proposal-bound durable attempt: typed submit options define the
candidate subject, evaluations resolve an existing canonical proposal, the actor
is derived from the local UID, and evaluator admission remains configuration-
gated. The supervised worker re-enters `hive proposal submit|evaluate TASK`;
`Attempts::Context` binds that argv to the admitted task and its current stage
(other proposal subcommands never run as attempts and fail closed), and the
controller applies the shared `Attempts::CommandDispatch` attach-result policy,
so a failed or lost worker exits non-zero instead of reporting success. It
writes an immutable `pse-*` inbox receipt and a
bounded task-activity correlation, commits the normal task paths plus the exact
inbox paths, and only then starts canonical ingestion in a second commit.

Committed `hive/state` blobs are authoritative. `Reconciler` ignores or restores
worktree-only remnants, scans only the bounded unconsumed index, replays a
committed receipt idempotently, and records permanent failures in a committed
terminal quarantine fact. Permanent quota/validation failures are quarantined;
transient source/blob failures remain pending without blocking later receipts in
the bounded queue. A failed quarantine commit is reported as a reconciliation
failure rather than clean convergence, and each receipt takes the commit lock
only for its own mutation. It never scans old task journals, benchmarks, skills,
workflows, or wiki prose, so existing projects are not backfilled.

Admission enforces configured project/proposal event and byte ceilings plus a
per-actor hourly source rate across the complete proposal namespace. Admission
reserves enough space for terminal status and the canonical mutation. The
published `hive-proposal-source-index.v1` contract retains bounded pending
recovery data, persistent project/proposal usage counters, and a pruned one-hour
actor window; a missing legacy index performs one bounded canonical bootstrap
scan. It rejects an oversized replacement before writing a receipt. Terminal
receipts use `hive-proposal-source-status.v1`. Lifecycle mutations use the same
aggregate and authority-rate ceilings. Before either Producer admission or a
lifecycle mutation reads that shared index, the service restores the committed
proposal namespace while holding the Git commit lock; reconciliation uses the
same restoration primitive. Producer also restores before its source-ID retry
lookup, so a direct service caller ignores crash-left worktree receipts and
judges historical retries from committed bytes without a separate CLI
reconciliation pass. Source IDs are idempotency keys: the
exact retry is a no-op and changed bytes under an existing ID are a conflict.

## Authority and lifecycle

Named evaluators are admitted at dispatch against configured workflow, stage,
and agent-profile bindings. Each allowlist is fail-closed, including an empty
list, and configuration loading and runtime admission share one row validator.
That historical evaluator binding is retained in the attempt and source event,
so later config revocation blocks new events without invalidating an
already-admitted receipt.

Decisions, supersession, and rollback use a separate configured operator or
policy authority. Every operation compares the caller's observed lifecycle head
version/digest. A decision additionally names the exact evaluation IDs it
considered together with each caller-observed result digest. Unrelated
evaluation appends do not stale the decision, while a changed lifecycle fact or
missing/changed considered evaluation does. Projection revalidates every stored
snapshot against the referenced evaluation's evaluator, method, outcome, and
result digest, quarantining contradictory histories. Lifecycle success requires
the immutable event bytes to be visible at the committed Hive-state head. One
accepted/rejected decision wins—there is no last-writer-wins path.

An empty considered set is valid only for an authority-authored rejection with
`rationale_category=no_evaluation`. Supersession requires a distinct existing
successor with the same subject and a matching requested predecessor; self-links,
duplicate successors, and cycles fail. Rollback requires historical acceptance,
the exact reverted revision, a reason, and an external revert reference. It
records that external action but never executes it, and historical acceptance
remains visible after rollback.

The configured boundary is same-user capability, not cryptographic human proof.
Any unrestricted process running as the same OS user may be able to invoke a
configured operator capability; stronger identity separation is outside v1.

## Privacy, retention, and rendering

Project-visible text is bounded and secret-redacted before persistence.
Evaluation metric names pass through the same redaction boundary, and names
that collide after redaction are rejected rather than silently overwriting one
another.
Producer-requested visibility or retention may only narrow configured policy.
New source receipts intersect historical dispatch policy with current
visibility, retention, and allowed-link ceilings; committed exact retries keep
their historical policy so replay does not rewrite immutable bytes.
Unclassified evidence defaults to restricted/digest-only; restricted/private
evidence persists only safe labels, digests, byte/media metadata, classification,
declarative retention, and safe source references. Retention always reports
`enforcement=none`: v1 does not expire, hide, or delete canonical bytes.

`Projection` and `Query` are the shared live semantics for CLI and context.
`Compiler` reads an exact pinned state commit and deterministically emits
`wiki/proposals.json` plus `wiki/proposals.md`. JSON includes valid drafts; the
human summary omits drafts but retains rejected, superseded, and rolled-back
lessons, evaluation evidence digests, and safe method/decision/task/commit links.
Terminal source quarantines appear as diagnostics in live queries and both
compiled views. Pinned symlink blobs are materialized as inert bytes for logical
diagnosis, never as live symlink targets. The managed llm-wiki hook compiles
proposal-only batches without an LLM provider or ordinary breaker budget and
publishes the pair in one wiki commit. Refresh checks compare scratch compiler
output with that atomically published managed-ref pair, not files in the primary
checkout, and advance the published pin only for newer canonical proposal
commits. Transient Git or filesystem failures during pinned materialization
abort publication so the previously committed pair remains visible.

Automatic proposal context is available only when a durable attempt carries a
matching typed subject. Selection materializes one exact committed `hive/state`
snapshot, so uncommitted lifecycle writes that may still roll back never reach a
prompt. It includes closed facts—IDs, enums, timestamps, method
kinds, evaluator IDs, outcomes, fixed-label numeric metric values, and fixed
digests—ranked by exact subject and lineage. Arbitrary metric keys, free-form
method labels, revision/reference text, candidate prose, evidence summaries,
rationale, instructions, links, and restricted bytes are excluded. Selection
stops at the first whole item that would overflow the existing 4 KiB
prompt-appendix ceiling, preserving a ranked prefix; provenance records
configured/effective budget, selected IDs/digest, and truncation even when the
first ranked item cannot fit. A subject with no terminal match reports
`no_terminal_matches`, distinct from actual `budget_exhausted` truncation.

## Configuration

`proposals` is closed and fail-closed:

```yaml
proposals:
  evaluators:
    benchmark-reviewer:
      workflows: [coding]
      stages: [4-execute]
      agent_profiles: [codex]
  authorities:
    proposal-operator:
      kind: operator
      capabilities: [decide, supersede, rollback]
      version: 1
      revoked: false
  evidence:
    visibility: restricted
    retention: task
    allowed_link_schemes: [https]
  context:
    max_items: 20
    max_bytes: 2048
```

See [[commands/proposal]] for operator usage and JSON contracts.

## Backlinks

- [[architecture]] · [[state-model]] · [[component-boundaries]]
- [[modules/attempts]] · [[modules/git_ops]] · [[modules/secret_patterns]]
- [[commands/proposal]] · [[testing]]
