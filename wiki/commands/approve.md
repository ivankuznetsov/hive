---
title: hive approve
type: command
source: lib/hive/commands/approve.rb
created: 2026-04-25
updated: 2026-04-25
tags: [command, approval, json]
---

**TLDR**: `hive approve TARGET [--to STAGE] [--from STAGE] [--project NAME] [--force] [--json]` moves a task folder between stages and records a commit on `hive/state`. The agent-callable equivalent of shell `mv <task> <next-stage>/` — same effect, plus marker validation, ambiguity resolution, idempotency assertion, locking, rollback on commit failure, and a structured exit-code / JSON contract (success and error paths).

## Usage

```
hive approve <slug>                        # auto: current stage → next stage
hive approve <slug> --to <stage>           # explicit destination (forward or backward)
hive approve <slug> --from <stage>         # idempotency: assert current stage before advancing
hive approve <slug> --project <name>       # disambiguate when slug exists in 2+ projects
hive approve <slug> --force                # bypass terminal-marker check on forward move
hive approve <task-folder> [...]           # take a folder path instead of a slug
hive approve <slug> --json                 # machine-readable result (success AND error)
```

`<stage>` accepts either the full directory name (`3-plan`) or the short suffix (`plan`). Both `--to` and `--from` are validated against the closed enum at parse time (Thor `enum:` constraint).

## Steps performed (`Commands::Approve#call`)

1. `resolve_target`: path-shaped `TARGET` (contains `/` or starts with `~`/`.`) is used directly; bare slugs are searched across registered projects (filtered by `--project` if given). Multi-stage hits inside one project are flagged as ambiguous.
2. `Hive::Task.new(folder)` parses the path into `{project, stage, slug}`.
3. `validate_project_path_match!`: when both an absolute path and `--project` are given, the path's project must match the named project (no silent override).
4. `validate_from!`: if `--from` was passed, assert the task is at the named stage; raise `WrongStage` (4) on mismatch.
5. `resolve_destination`: `--to` (long or short stage name), or auto = current stage_index + 1. Past `6-done` raises `FinalStageReached` (also exit 4).
6. **Same-stage no-op**: if destination resolves to the current stage, emit a `noop: true` payload (or one-line `hive: noop —` text) and return success. No mv, no commit.
7. `validate_move!`: forward auto-advance requires `:complete` or `:execute_complete` marker. `--to` (backward direction) and `--force` both bypass.
8. **Locking**:
   - `Hive::Lock.with_commit_lock(hive_state_path)` outermost — serialises hive/state writes and surfaces contention BEFORE any filesystem mutation (a 30-second commit-lock timeout never leaves a half-applied move).
   - `Hive::Lock.with_task_lock(task.folder)` inner — blocks a concurrent `hive run` on the same task during the move.
9. `move_task!`: `FileUtils.mv` from source to destination; aborts on destination collision (`Hive::DestinationCollision`).
10. Cleanup: the task `.lock` file moves with the folder; the orphan at the destination is deleted before commit so per-process lock metadata isn't tracked in hive/state.
11. `record_hive_commit`: **slug-scoped** `git add -A stages/<src>/<slug> stages/<dst>/<slug>` (the source side is added only if it has tracked files; the destination is always added). Sibling-task changes in the same parent stage directory do NOT get swept into the commit message. Commit message: `hive: <from>/<slug> approve <from> -> <to>`.
12. **Rollback**: if the commit fails (pre-commit hook abort, disk full, lock contention mid-flight), the move is reversed (`FileUtils.mv` back) and the original error is re-raised wrapped in `Hive::Error` so filesystem and git history don't diverge.
13. Report: human prose by default (`hive: approved <slug>` to stdout, `next: hive run …` hint to stderr); one-line `hive-approve` JSON document with `--json`.

## JSON contract (`schema = "hive-approve"`, version 1)

### Success

```json
{
  "schema": "hive-approve",
  "schema_version": 1,
  "ok": true,
  "noop": false,
  "slug": "fix-bug-260424-aaaa",
  "from_stage": "brainstorm",
  "from_stage_index": 2,
  "from_stage_dir": "2-brainstorm",
  "to_stage": "plan",
  "to_stage_index": 3,
  "to_stage_dir": "3-plan",
  "direction": "forward",
  "forced": false,
  "from_marker": "complete",
  "from_folder": "/home/you/Dev/proj/.hive-state/stages/2-brainstorm/fix-bug-260424-aaaa",
  "to_folder":   "/home/you/Dev/proj/.hive-state/stages/3-plan/fix-bug-260424-aaaa",
  "commit_action": "approve 2-brainstorm -> 3-plan",
  "next_action": {
    "kind": "run",
    "folder": "/home/you/Dev/proj/.hive-state/stages/3-plan/fix-bug-260424-aaaa",
    "command": "hive run /home/you/Dev/proj/.hive-state/stages/3-plan/fix-bug-260424-aaaa"
  }
}
```

The split `from_stage` (bare) + `from_stage_index` + `from_stage_dir` (combined) shape mirrors `hive-run`'s `stage` / `stage_index` so a consumer can compare across schemas without string parsing. `next_action.kind` is drawn from the closed `Hive::Schemas::NextActionKind` enum (`edit`, `mv`, `run`, `recover_stale`, `no_op`).

### Error envelope (every failure path under `--json`)

```json
{
  "schema": "hive-approve",
  "schema_version": 1,
  "ok": false,
  "error_class": "AmbiguousSlug",
  "error_kind": "ambiguous_slug",
  "exit_code": 64,
  "message": "slug 'X' is ambiguous (in projA, projB); pass --project <name>",
  "candidates": [
    { "project": "projA", "stage": "1-inbox", "folder": "..." },
    { "project": "projB", "stage": "1-inbox", "folder": "..." }
  ]
}
```

Different errors carry different structured fields:
- `AmbiguousSlug` → `candidates: [{project, stage, folder}, ...]`
- `DestinationCollision` → `path: "<conflicting destination>"`
- `FinalStageReached` → `stage: "6-done"`

The envelope is emitted on stdout BEFORE the exception propagates, mirroring `hive run --json`'s dual-signal pattern (JSON document + non-zero exit code).

Pinned by `Hive::Schemas::SCHEMA_VERSIONS["hive-approve"]` and `test/integration/run_approve_test.rb` (`test_json_output_emits_stable_schema` for the success path; one test per error class for envelopes).

## Slug resolution rules

- **Slug not found**: `Hive::InvalidTaskPath` → exit 64 (USAGE).
- **Slug appears in multiple stages of the same project**: `Hive::AmbiguousSlug` → exit 64. Pass an absolute folder path or use `--to` to disambiguate. (The previous "lowest stage wins" heuristic was wrong for partial-failure-recovery cases where the lower stage is the stale leftover.)
- **Slug appears in multiple projects**: `Hive::AmbiguousSlug` → exit 64 with a hint to pass `--project <name>`.
- **`--project NAME`** scopes the slug lookup to a single registered project. Combining `--project` with an absolute folder path is allowed only if the path's project matches the name; mismatch raises `Hive::InvalidTaskPath`.
- **Bare slug + cwd shadow**: a bare slug is always resolved through the cross-project search even if a directory of the same name exists in `pwd`.

## Marker policy

| Direction | Marker required | Override |
|-----------|-----------------|----------|
| Forward auto (no `--to`) | `:complete` or `:execute_complete` | `--force` |
| Forward via `--to`       | `:complete` or `:execute_complete` | `--force` |
| Backward via `--to`      | none                                | n/a      |
| Same stage (no-op)       | none                                | n/a      |

`:error` is treated like any other non-terminal marker on forward auto — the message includes `marker is :error` so an agent can branch deterministically. Backward `--to` is the recovery lever (e.g. `hive approve <slug> --to 3-plan` after an execute crash).

## Idempotency: `--from`

```
hive approve <slug> --from 2-brainstorm
```

If the task is at `2-brainstorm`, advance to `3-plan` as usual. If it's at any other stage (because a prior call already advanced it, or because the user mv'd it manually), raise `Hive::WrongStage` (exit 4) with `task is at <actual> but --from expected 2-brainstorm`. Pass `--from` on every retry so a network blip mid-call doesn't silently advance the task two stages on the next attempt.

## Exit codes

| Condition | Exit | Class |
|-----------|------|-------|
| Success | 0 | — |
| Slug not found / unknown `--to` or `--from` stage / `--project` path mismatch | 64 (`USAGE`) | `Hive::InvalidTaskPath` |
| Slug ambiguous (cross-project or multi-stage in one project) | 64 (`USAGE`) | `Hive::AmbiguousSlug` |
| Forward move without terminal marker (no `--force`) | 4 (`WRONG_STAGE`) | `Hive::WrongStage` |
| `--from` mismatch (task at different stage than asserted) | 4 (`WRONG_STAGE`) | `Hive::WrongStage` |
| Advancing past `6-done` | 4 (`WRONG_STAGE`) | `Hive::FinalStageReached` |
| Destination already exists | 1 (`GENERIC`) | `Hive::DestinationCollision` |
| Commit failed; mv rolled back | 1 (`GENERIC`) | `Hive::Error` |
| Lock contention (commit lock held >30s) | 75 (`TEMPFAIL`) | `Hive::ConcurrentRunError` |

## Why not just use `mv`?

`mv` works fine for humans. Agent callers want:
- a stable exit code on each failure mode, including the dual-signal JSON envelope on every error path
- a single source of truth for stage names (`--to plan` ≡ `--to 3-plan`; enforced by Thor `enum:`)
- a marker check that prevents "approve a WAITING task" mistakes
- an idempotency assertion (`--from`) so retries don't silently double-advance
- locking that blocks concurrent `hive run` on the same task
- atomic move-and-commit semantics: a commit failure rolls the move back so fs and git history stay in sync
- a slug-scoped commit so the audit trail isn't polluted by sibling-task changes
- an audit-trail commit on `hive/state` recording the approval

`hive approve` adds all of that without removing the manual `mv` path — the two coexist.

## Backlinks

- [[cli]]
- [[commands/run]]
- [[commands/status]]
- [[stages/index]]
