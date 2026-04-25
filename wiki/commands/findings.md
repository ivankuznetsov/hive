---
title: hive findings / accept-finding / reject-finding
type: command
source: lib/hive/commands/findings.rb, lib/hive/commands/finding_toggle.rb
created: 2026-04-25
updated: 2026-04-25
tags: [command, findings, review, json]
---

**TLDR**: `hive findings TARGET [--pass N] [--json]` lists the GFM-checkbox findings that the execute-stage reviewer wrote into `<task>/reviews/ce-review-NN.md`. `hive accept-finding TARGET ID...` ticks `[ ]` → `[x]` so a finding is re-injected into the next implementation pass; `hive reject-finding TARGET ID...` toggles back. The agent-callable replacement for hand-editing the review markdown.

## Usage

```
hive findings <slug>                          # list findings of latest pass
hive findings <slug> --pass 1                 # specific pass
hive findings <slug> --json                   # machine-readable

hive accept-finding <slug> 1 3 5              # tick by IDs
hive accept-finding <slug> --severity high    # tick all High findings
hive accept-finding <slug> --all              # tick everything
hive accept-finding <slug> --json             # JSON envelope (success and error)

hive reject-finding <slug> 2                  # untick id 2
hive reject-finding <slug> --severity nit     # untick all Nit findings
```

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

1. Resolve TARGET via `Hive::TaskResolver` (path or slug; cross-project with `--project`).
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
8. Emit text or JSON report including a `next_action` pointing at `hive run <task.folder>` to consume the new accepted set.

## JSON contract (`schema = "hive-findings"`, version 1)

### List success (`hive findings --json`)

```json
{
  "schema": "hive-findings",
  "schema_version": 1,
  "ok": true,
  "slug": "fix-bug-260424-aaaa",
  "stage": "execute",
  "stage_dir": "4-execute",
  "task_folder": "/.../4-execute/fix-bug-260424-aaaa",
  "review_file": "/.../4-execute/fix-bug-260424-aaaa/reviews/ce-review-02.md",
  "pass": 2,
  "findings": [
    {
      "id": 1,
      "severity": "high",
      "accepted": false,
      "title": "memory leak in worker pool",
      "justification": "process_pool doesn't drain on shutdown"
    }
  ],
  "summary": {
    "total": 5,
    "accepted": 1,
    "by_severity": { "high": 2, "medium": 2, "nit": 1 }
  }
}
```

### Toggle success (`hive accept-finding --json` / `hive reject-finding --json`)

```json
{
  "schema": "hive-findings",
  "schema_version": 1,
  "ok": true,
  "operation": "accept",
  "slug": "fix-bug-260424-aaaa",
  "review_file": "/.../ce-review-02.md",
  "pass": 2,
  "selected_ids": [1, 3],
  "changes": [
    { "id": 1, "severity": "high", "was": false, "now": true },
    { "id": 3, "severity": "medium", "was": false, "now": true }
  ],
  "noop": false,
  "summary": { "total": 5, "accepted": 3, "by_severity": { "high": 2, "medium": 2, "nit": 1 } },
  "next_action": {
    "kind": "run",
    "folder": "/.../4-execute/fix-bug-260424-aaaa",
    "command": "hive run /.../4-execute/fix-bug-260424-aaaa",
    "reason": "3 accepted finding(s) need a fresh implementation pass"
  }
}
```

The `changes` array is a subset of `selected_ids` — entries with no state change (idempotent re-toggle) are dropped. `noop: true` on the envelope means every selected ID was already in the requested state.

### Error envelope

```json
{
  "schema": "hive-findings",
  "schema_version": 1,
  "ok": false,
  "operation": "accept",
  "error_class": "UnknownFinding",
  "error_kind": "unknown_finding",
  "exit_code": 64,
  "message": "no finding with id=99 in /.../ce-review-02.md (valid: [1, 2, 3, 4, 5])",
  "id": 99
}
```

`error_kind` enum: `ambiguous_slug`, `no_review_file`, `unknown_finding`, `invalid_task_path`, `error`.

External consumers can validate against `schemas/hive-findings.v1.json`; resolve the path via `Hive::Schemas.schema_path("hive-findings")`.

## Exit codes

| Condition | Exit | Class |
|-----------|------|-------|
| Success | 0 | — |
| No findings selected (caller passed nothing actionable) | 64 (`USAGE`) | `Hive::InvalidTaskPath` |
| Unknown finding ID | 64 (`USAGE`) | `Hive::UnknownFinding` |
| No review file at the requested pass | 64 (`USAGE`) | `Hive::NoReviewFile` |
| Slug ambiguous / unknown / `--project` mismatch | 64 (`USAGE`) | `Hive::InvalidTaskPath` / `AmbiguousSlug` |
| Task lock held by another process | 75 (`TEMPFAIL`) | `Hive::ConcurrentRunError` |
| Internal error (Errno, SystemCallError) | 70 (`SOFTWARE`) | `Hive::InternalError` |

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
