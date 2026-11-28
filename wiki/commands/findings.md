---
title: hive findings / accept-finding / reject-finding
type: command
source: lib/hive/commands/findings.rb, lib/hive/commands/finding_toggle.rb
created: 2026-04-25
updated: 2026-09-02
tags: [command, findings, review, json]
---

> **Public CLI authority:** See [docs/cli.md](../../docs/cli.md#findings-triage) for canonical invocation syntax, options, JSON schemas, context rules, and exit codes. This page documents internal implementation, storage, and architecture.

**TLDR**: `hive findings TARGET [--pass N] [--json]` lists the GFM-checkbox findings that the execute-stage reviewer wrote into `<task>/reviews/ce-review-NN.md`. `hive accept-finding TARGET ID...` ticks `[ ]` → `[x]` so a finding is re-injected into the next implementation pass; `hive reject-finding TARGET ID...` toggles back. The agent-callable replacement for hand-editing the review markdown.

## Data model

The reviewer prompt writes a markdown file with severity headings and unchecked findings:

```markdown
## High
- [ ] memory leak in worker pool: process_pool doesn't drain on shutdown
- [x] missing rate limit on /api/upload: 100req/s burst seen in load test

## Medium
- [ ] redundant validation in form_helper.rb: server-side already validates
```

`Hive::Findings::Document` parses each `- [ ]` / `- [x]` line into a `Finding` record. IDs are 1-based and assigned in document order, so `id 1` is the first finding under any heading, `id 2` is the next, etc. Severity comes from the most recent `## Heading` (lowercased; `unknown` if no heading precedes the finding).

`Hive::Stages::Execute#collect_accepted_findings` reads the latest review file at the start of the next execute pass and re-injects any `[x]` lines into the implementation prompt. The toggle commands change those checkboxes deterministically without hand-editing markdown.

## Steps performed

`hive findings` (`Hive::Commands::Findings#call`):

1. Resolve TARGET via `Hive::TaskResolver` (path or slug; cross-project with `--project`; same-slug stage collisions with `--stage`).
2. `Hive::Findings.review_path_for(task, pass:)` picks `<reviews>/ce-review-NN.md` (latest by default).
3. `Hive::Findings::Document.new(path)` parses the file.
4. Emit table on stdout (default) or single-line `hive-findings` JSON document with `--json`.

`hive accept-finding` / `hive reject-finding` (`Hive::Commands::FindingToggle#call`):

1. Resolve TARGET; load the review document.
2. **Lock**: `Hive::Lock.with_task_lock(task.folder)` blocks concurrent `hive run` / other toggles on this task.
3. Compute the union of `ID...` positionals + `--severity <s>` + `--all`. Empty union is an error.
4. Validate every selected ID exists in the document; unknown IDs raise `Hive::UnknownFinding` (exit 64).
5. For each selected ID, flip its checkbox to the target state. Already-correct entries are no-ops.
6. Atomic write: tempfile + `File.rename`.
7. Commit the change to `hive/state` (slug-scoped `git add`, single commit per command).
8. Emit text or JSON report including a `next_action` pointing at `hive develop <slug>` to consume the new accepted set.

## Locking

`hive accept-finding` and `hive reject-finding` acquire `Hive::Lock.with_task_lock(task.folder)`, the same lock `hive run` holds during a stage execution. A toggle attempt while a `hive run` is mid-flight surfaces `ConcurrentRunError` (exit 75) instead of racing with the agent.

`hive findings` is read-only and takes no lock.

## Why not just edit the file?

Hand-editing the review markdown still works (and `hive run` reads the same `[x]`-checked lines). Agent callers want:
- a stable enumeration of findings with IDs that don't depend on line numbers
- a structured exit code per failure mode (no parsing stderr to learn "ID didn't exist")
- a JSON output mode with full per-finding shape (severity, title, justification)
- atomic write semantics so a crash mid-edit can't leave the file with a malformed checkbox
- locking so concurrent `hive run` can't race against the toggle
- an audit-trail commit on hive/state

`hive findings` / `accept-finding` / `reject-finding` provide all of that without removing the manual-edit path — the two coexist.

## Backlinks

- [[cli]] · [[commands/run]] · [[commands/approve]]
- [[stages/execute]] — the stage that produces review files
- [[modules/lock]] — task lock used by the toggle commands
