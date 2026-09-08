---
title: hive proposal
type: command
source: lib/hive/commands/proposal.rb, lib/hive/cli.rb, lib/hive/proposals/
created: 2026-08-30
updated: 2026-09-08
tags: [command, proposals, skills, workflows, evidence]
---

**TLDR**: `hive proposal` submits and evaluates task-bound skill/workflow
candidates, exposes live canonical history, records authority-gated lifecycle
facts, and refreshes deterministic wiki views. Every mutation is tracking-only.

## Discovery

```bash
hive proposal list [PROJECT_PATH]
hive proposal list [PROJECT_PATH] --include-drafts --json
hive proposal show PROPOSAL_ID [--include-quarantine] [--json]
hive proposal filter [PROJECT_PATH] \
  [--kind skill|workflow] [--subject REF] [--revision REV] \
  [--status STATUS] [--relation PROPOSAL_ID] \
  [--evaluator ID] [--method LABEL] \
  [--include-drafts] [--include-quarantine] [--json]
```

List excludes drafts by default. Filter uses the same normalized query semantics
as automatic context and opts into drafts explicitly. Show returns the complete
immutable event history, including contradictory/post-decision evaluations,
decision evidence, lineage, rollback, provenance, classifications, retention,
fresh lifecycle head, and safe diagnostics. These commands read live canonical
state, not the potentially lagging wiki branch. On a pre-feature project they
return an empty result without creating `proposals/v1` or scanning historical
task journals; only a newly admitted typed source event initializes the ledger.
`--include-quarantine` also exposes safe terminal diagnostics for source receipts
that could not be admitted into canonical history.

JSON discovery uses `hive-proposal-list.v1` and `hive-proposal-show.v1`.
Terminal rendering escapes control syntax; JSON and Markdown use their own
structural encoders.

## Task-bound source commands

```bash
hive proposal submit TASK --input candidate.json [--project NAME] [--json]
hive proposal evaluate TASK --input evaluation.json [--project NAME] [--json]
```

Both require a real durable proposal-bound task attempt. The controller or
dispatcher must have admitted the subject and actor; evaluation additionally
requires a named evaluator binding. `--input` cannot supply or replace actor,
subject, evaluator, or configuration identity.

A submission artifact contains `proposed_change`, `motivation`, `evidence`, and
optional `lineage`, `source_event_id`, or `idempotency_key`. An evaluation
contains `method`, typed `result` (`outcome` plus numeric/boolean/null metrics),
`rationale`, `evidence`, optional links, and optional source/idempotency key.
The regular non-symlink JSON file must be bounded and project-relative.

The command commits the inbox receipt before synchronous ingestion. A failure
after source commit remains recoverable; a failure before it restores task,
activity, and inbox paths together.

## Lifecycle commands

```bash
hive proposal decide PROPOSAL_ID --input decision.json \
  --authority ID --policy-fingerprint SHA256 \
  --expected-head-version N --expected-head-digest SHA256 \
  --considered-evaluations EVENT_ID ...

hive proposal supersede PROPOSAL_ID --input supersession.json \
  --authority ID --policy-fingerprint SHA256 \
  --expected-head-version N --expected-head-digest SHA256

hive proposal rollback PROPOSAL_ID --input rollback.json \
  --authority ID --policy-fingerprint SHA256 \
  --expected-head-version N --expected-head-digest SHA256
```

Read `list` or `show` immediately before mutation and pass its lifecycle head.
Decision input supplies `outcome`, `rationale_category`, `rationale`, links, and
an idempotency key. Supersession input supplies `successor_id` and an idempotency
key. Rollback input supplies `reverted_revision`, `reason`, `external_revert`,
and an idempotency key. Policy authorities additionally supply their closed
policy receipt inside the input document.

Successful source and lifecycle mutations use `hive-proposal-mutation.v1`.
JSON failures retain the selected proposal schema and one of the stable kinds
`unauthorized`, `stale`, `conflict`, `quota`, `quarantine`,
`source_unavailable`, `config`, or `invalid`.

## Generated views

```bash
hive proposal refresh [PROJECT_PATH]
hive proposal refresh [PROJECT_PATH] --check
```

Refresh enters the managed llm-wiki publication boundary. Proposal-only state
commits invoke the pure compiler without a provider; mixed batches run the wiki
agent first and then overwrite the generated proposal pair from the pinned
state source. Both files publish in one wiki commit. `--check` compiles to an
external disposable directory, compares bytes, removes the scratch output, and
does not publish or modify a managed worktree.

An explicit refresh enqueues the selected pinned proposal source even when the
current state `HEAD` changes only inbox/cursor/task-state paths. Queued proposal
sources are selected by commit ancestry, so equal timestamps cannot choose an
older ancestor. Ordinary wiki batches restore the generated pair before staging,
preventing agent edits from fabricating proposal facts or publishing a torn pair.

Automatic inbox/index/cursor-only commits and commits touching only the generated
pair do not queue another refresh. The hidden
`--compile-only --source-ref --output-root` surface is reserved for the managed
hook.

## Tracking-only guarantee

No subcommand calls skill provision/publish paths, changes
`config/agent-skills.yml`, mutates workflow-package stores, installs a workflow,
or executes a compensating revert. Acceptance and rollback are historical facts,
not activation commands.

## Backlinks

- [[modules/proposals]] · [[state-model]] · [[cli]] · [[testing]]
