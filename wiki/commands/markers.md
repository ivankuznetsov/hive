---
title: hive markers
type: command
source: lib/hive/commands/markers.rb
created: 2026-04-26
updated: 2026-09-02
tags: [command, markers, recovery, json]
---

> **Public CLI authority:** See [docs/cli.md](../../docs/cli.md#hive-markers-clear) for canonical invocation syntax, options, JSON schemas, context rules, and exit codes. This page documents internal implementation, storage, and architecture.

**TLDR**: `hive markers clear FOLDER --name <NAME> [--project NAME]
[--json]` is a low-level maintenance command that validates and removes marker
history while holding the project commit lock, typed task lease, and narrower
marker writer mutex in that order, then records a `hive_commit`. Normal agent
recovery uses the fresh `workflow.retry` action from operational status.

## Allowlist

Only recovery markers are clearable. Terminal-success markers (`REVIEW_COMPLETE`, `EXECUTE_COMPLETE`, `COMPLETE`) are deliberately excluded — those gate `hive approve`'s forward-advance check and clearing them would let an agent skip the approval gesture.

| Marker | When the runner sets it | What clearing it does |
|--------|-------------------------|-----------------------|
| `REVIEW_STALE`      | `Stages::Review` after `max_passes` or wall-clock cap                    | next `hive run` retries the highest pass when `escalations-NN.md` is missing, otherwise re-evaluates against the cleaned `reviews/` files |
| `REVIEW_CI_STALE`   | `Stages::Review::CiFix` after `review.ci.max_attempts` red runs          | next `hive run` re-runs Phase 1 against the current `bin/ci`      |
| `REVIEW_ERROR`      | `Stages::Review` on triage / fix / browser / runner-exception failures   | next `hive run` re-evaluates from pre-flight                       |
| `EXECUTE_STALE`     | `Stages::Execute` on stale interrupt                                     | next `hive run` re-evaluates the execute state machine             |
| `ERROR`             | any stage's agent on a recoverable failure                               | next `hive run` re-enters the stage from pre-flight                |

`REVIEW_COMPLETE` / `EXECUTE_COMPLETE` / `COMPLETE` are not on the allowlist. To advance past them, use [[commands/approve]] (which validates them as forward-advance gates). To roll a task backward, use `hive approve <slug> --to <stage>`.

## Steps performed (`Commands::Markers#call`)

1. Parse the subcommand (`clear` is the only verb in v1).
2. Resolve `FOLDER` via the shared `Hive::TaskResolver`: path-shaped (contains `/` or starts with `~`/`.`) → expanded + realpath'd; bare slug or numeric task id → searched across registered projects (filtered by `--project` if given) over each project's registered workflow stage union, so tasks in runtime-registered workflow stages resolve too. Multi-stage hits inside one project are flagged as ambiguous — identical rules to [[commands/approve]] and the other resolver consumers.
3. Validate the requested `--name` against `Hive::Commands::Markers::ALLOWED_NAMES`. Anything else raises `Hive::WrongStage` (exit 4).
4. Acquire the project commit lock, then the stable task lease. A live runner
   refuses the clear before any file or index mutation.
5. Under the marker writer mutex, re-resolve the task and read the current
   marker. Require the requested name and every `--match-attr` pair to match
   this locked observation; otherwise raise `Hive::WrongStage`.
6. Remove every recognized marker comment with
   `Hive::Markers.remove_all_markers`, preserving prose and headings. Removing
   only the latest marker could expose a shadowed transient/error marker.
7. Record `hive: <stage>/<slug> markers clear <NAME>` while all three scopes
   remain held, then release in reverse order.
8. Emit the human or one-line JSON summary and next-run hint.

## Why this maintenance command exists

Direct file editing is never safe marker maintenance:

- **No deterministic exit code on success/failure.** A regex replace either touches the file or doesn't; an agent can't tell whether the marker was actually present.
- **No marker-vs-state guard.** `sed -i` happily deletes any HTML comment matching a regex, including `<!-- REVIEW_COMPLETE -->`. The allowlist + actual-marker check refuses both forms of mistake.
- **No audit trail.** Hand-edits don't land on the `hive/state` branch; future `hive metrics` walks miss the recovery action entirely.
- **No JSON envelope.** `hive markers clear --json` remains scriptable for explicit maintenance, but it does not create a durable continuation. Use `hive act workflow.retry ...` for ordinary recovery.

## Backlinks

- [[cli]]
- [[commands/approve]]
- [[commands/run]]
- [[stages/review]]
- [[modules/markers]]
