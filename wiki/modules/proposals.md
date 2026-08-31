---
title: Skill and workflow proposal tracking
type: module
source: lib/hive/proposals.rb, lib/hive/proposals/, schemas/hive-proposal-*.v1.json
created: 2026-08-30
updated: 2026-08-30
tags: [proposals, skills, workflows, evidence, lifecycle, history]
---

**TLDR**: `Hive::Proposals` is a tracking-only, project-level history for skill
and workflow candidate revisions. Durable proposal-bound task attempts may open
candidates and append evaluations. Configured lifecycle authorities may append
decisions, supersession, and rollback evidence. Nothing in this module installs,
publishes, activates, removes, or reverts an active skill or workflow.

## Canonical state

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
valid neighbors remain queryable and compilable. Malformed event filenames
reserve their numeric version so recovery never overwrites unknown bytes.

## Durable source admission

`Producer` is the only submission/evaluation admission boundary. It reconstructs
the proposal subject, actor, optional evaluator, configuration fingerprint, and
evidence policy from the durable `Attempts::Record`; CLI text and artifact fields
cannot create those bindings. It writes an immutable `pse-*` inbox receipt and a
bounded task-activity correlation, commits the normal task paths plus the exact
inbox paths, and only then starts canonical ingestion in a second commit.

Committed `hive/state` blobs are authoritative. `Reconciler` ignores or restores
worktree-only remnants, scans only the bounded unconsumed index, replays a
committed receipt idempotently, and records permanent failures in a committed
terminal quarantine fact. It never scans old task journals, benchmarks, skills,
workflows, or wiki prose, so existing projects are not backfilled.

Admission enforces configured project/proposal event and byte ceilings plus a
per-actor hourly source rate. Source IDs are idempotency keys: the exact retry is
a no-op and changed bytes under an existing ID are a conflict.

## Authority and lifecycle

Named evaluators are admitted at dispatch against configured workflow, stage,
and agent-profile bindings. That historical evaluator binding is retained in the
attempt and source event, so later config revocation blocks new events without
invalidating an already-admitted receipt.

Decisions, supersession, and rollback use a separate configured operator or
policy authority. Every operation compares the caller's observed lifecycle head
version/digest. A decision additionally names the exact evaluation IDs it
considered; unrelated evaluation appends do not stale the decision, while a
changed lifecycle fact or missing/changed considered evaluation does. One
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
Producer-requested visibility or retention may only narrow configured policy.
Unclassified evidence defaults to restricted/digest-only; restricted/private
evidence persists only safe labels, digests, byte/media metadata, classification,
declarative retention, and safe source references. Retention always reports
`enforcement=none`: v1 does not expire, hide, or delete canonical bytes.

`Projection` and `Query` are the shared live semantics for CLI and context.
`Compiler` reads an exact pinned state commit and deterministically emits
`wiki/proposals.json` plus `wiki/proposals.md`. JSON includes valid drafts; the
human summary omits drafts but retains rejected, superseded, and rolled-back
lessons. The managed llm-wiki hook compiles proposal-only batches without an LLM
provider or ordinary breaker budget and publishes the pair in one wiki commit.

Automatic proposal context is available only when a durable attempt carries a
matching typed subject. It includes closed facts—IDs, enums, timestamps, method
labels, evaluator IDs, and numeric/boolean/null metrics—ranked by exact subject
and lineage. Candidate prose, evidence summaries, rationale, instructions,
links, and restricted bytes are excluded. Whole items share the existing 4 KiB
prompt-appendix ceiling, and selection provenance records configured/effective
budget, selected IDs/digest, and truncation in task activity.

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
