---
title: hive markers
type: command
source: lib/hive/commands/markers.rb
created: 2026-04-26
updated: 2026-04-26
tags: [command, markers, recovery, json]
---

**TLDR**: `hive markers clear FOLDER --name <NAME> [--project NAME] [--json]` removes a single recovery marker from a task's state file (atomic write) and records a `hive_commit` so the audit trail stays accurate. Replaces the previous "manually edit `task.md` and delete the marker comment" recovery prose with a deterministic, agent-callable surface.

## Usage

```
hive markers clear <slug>          --name REVIEW_STALE       # bare slug
hive markers clear <task-folder>   --name REVIEW_CI_STALE    # explicit path
hive markers clear <slug>          --name REVIEW_ERROR --project myproj
hive markers clear <slug>          --name REVIEW_STALE --json
```

## Allowlist

Only recovery markers are clearable. Terminal-success markers (`REVIEW_COMPLETE`, `EXECUTE_COMPLETE`, `COMPLETE`) are deliberately excluded — those gate `hive approve`'s forward-advance check and clearing them would let an agent skip the approval gesture.

| Marker | When the runner sets it | What clearing it does |
|--------|-------------------------|-----------------------|
| `REVIEW_STALE`      | `Stages::Review` after `max_passes` or wall-clock cap                    | next `hive run` re-evaluates against the current `reviews/` files |
| `REVIEW_CI_STALE`   | `Stages::Review::CiFix` after `review.ci.max_attempts` red runs          | next `hive run` re-runs Phase 1 against the current `bin/ci`      |
| `REVIEW_ERROR`      | `Stages::Review` on triage / fix / browser / runner-exception failures   | next `hive run` re-evaluates from pre-flight                       |
| `EXECUTE_STALE`     | `Stages::Execute` on stale interrupt                                     | next `hive run` re-evaluates the execute state machine             |
| `ERROR`             | any stage's agent on a recoverable failure                               | next `hive run` re-enters the stage from pre-flight                |

`REVIEW_COMPLETE` / `EXECUTE_COMPLETE` / `COMPLETE` are not on the allowlist. To advance past them, use [[commands/approve]] (which validates them as forward-advance gates). To roll a task backward, use `hive approve <slug> --to <stage>`.

## Steps performed (`Commands::Markers#call`)

1. Parse the subcommand (`clear` is the only verb in v1).
2. Resolve `FOLDER`: path-shaped (contains `/` or starts with `~`/`.`) → used directly; bare slug → searched across registered projects (filtered by `--project` if given). Multi-stage hits inside one project are flagged as ambiguous (mirrors `hive approve`).
3. Validate the requested `--name` against `Hive::Commands::Markers::ALLOWED_NAMES`. Anything else raises `Hive::WrongStage` (exit 4).
4. Read the current marker via `Hive::Markers.current(state_file)`. If the marker name does NOT match `--name`, raise `Hive::WrongStage` — refusing to silently clear a different state.
5. Remove the marker line: `File.read` the body, `sub` out the exact `marker.raw` comment plus its trailing newline (if it sat alone on a line), then `Hive::Markers.write_atomic` the result. Surrounding prose, headings, and other markers stay untouched.
6. Record a `hive_commit` on the `hive/state` branch (`hive: <stage>/<slug> markers clear <NAME>`).
7. Emit a stdout summary (or one-line `hive-markers-clear` JSON document with `--json`); print a `next: hive run <folder>` hint to stderr.

## JSON contract (`schema = "hive-markers-clear"`, version 1)

### Success

```json
{
  "schema": "hive-markers-clear",
  "schema_version": 1,
  "ok": true,
  "folder": "/home/you/Dev/proj/.hive-state/stages/5-review/feat-x-260424-aaaa",
  "slug": "feat-x-260424-aaaa",
  "marker_cleared": "REVIEW_STALE"
}
```

### Error envelope (every failure path under `--json`)

```json
{
  "schema": "hive-markers-clear",
  "schema_version": 1,
  "ok": false,
  "error_class": "WrongStage",
  "error_kind": "wrong_stage",
  "exit_code": 4,
  "message": "hive markers clear: marker \"REVIEW_COMPLETE\" is not in the allowlist (...)"
}
```

The `error_kind` enum mirrors `hive approve --json`: `ambiguous_slug`, `wrong_stage`, `invalid_task_path`, `error`. The published JSON Schema lives at `schemas/hive-markers-clear.v1.json`.

## Exit codes

| Condition | Exit | Class |
|-----------|------|-------|
| Success | 0 | — |
| Slug not found / unknown subcommand / missing `FOLDER` or `--name` | 64 (`USAGE`) | `Hive::InvalidTaskPath` |
| Slug ambiguous (cross-project or multi-stage in one project) | 64 (`USAGE`) | `Hive::AmbiguousSlug` |
| Marker not in allowlist (e.g. `REVIEW_COMPLETE`) | 4 (`WRONG_STAGE`) | `Hive::WrongStage` |
| Requested `--name` does not match the actual marker on the file | 4 (`WRONG_STAGE`) | `Hive::WrongStage` |
| Internal failure (git, fs) | 70 (`SOFTWARE`) | `Hive::InternalError` |

## Why a typed command instead of `sed -i`?

The old recovery prose was "remove the marker, then re-run `hive run`". That worked for humans but broke for agents:

- **No deterministic exit code on success/failure.** A regex replace either touches the file or doesn't; an agent can't tell whether the marker was actually present.
- **No marker-vs-state guard.** `sed -i` happily deletes any HTML comment matching a regex, including `<!-- REVIEW_COMPLETE -->`. The allowlist + actual-marker check refuses both forms of mistake.
- **No audit trail.** Hand-edits don't land on the `hive/state` branch; future `hive metrics` walks miss the recovery action entirely.
- **No JSON envelope.** `hive markers clear --json` is part of the same agent-callable surface as `hive approve --json` and `hive run --json`.

## Backlinks

- [[cli]]
- [[commands/approve]]
- [[commands/run]]
- [[stages/review]]
- [[modules/markers]]
