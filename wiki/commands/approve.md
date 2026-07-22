---
title: hive approve
type: command
source: lib/hive/commands/approve.rb
created: 2026-04-25
updated: 2026-07-16
tags: [command, approval, json, dependencies, admission]
---

**TLDR**: `hive approve` moves a task folder and commits the transition. Forward moves revalidate dependency admission under the existing commit/task locks immediately before mutation. Backward recovery and same-stage no-ops remain available; `--force` cannot bypass admission.

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

1. `resolve_target`: path-shaped `TARGET` (contains `/` or starts with `~`/`.`) is used directly; bare slugs are searched across registered projects (filtered by `--project` if given). Multi-stage hits inside one project are flagged as ambiguous. The resolved folder is then `File.realpath`'d so slug-named symlinks pointing outside the `.hive-state` hierarchy are rejected at the PATH_RE check.
2. `Hive::Task.new(folder)` parses the path into `{project, stage, slug}`.
3. `validate_project_path_match!`: when both an absolute path and `--project` are given, the path's project must match the named project (no silent override).
4. `validate_from!`: if `--from` was passed, assert the task is at the named stage; raise `WrongStage` (4) on mismatch.
5. `resolve_destination`: `--to` (long or short stage name), or auto = the descriptor's next stage (`task.workflow.next_stage_after(task.stage_name)`). At the terminal stage (`9-done` for coding) this raises `FinalStageReached` (also exit 4).
6. **Same-stage no-op**: if destination resolves to the current stage, emit a `noop: true` payload (or one-line `hive: noop —` text) and return success. No mv, no commit.
7. `validate_move!`: forward auto-advance requires `:complete`, `:execute_complete`, or `:review_complete` marker. At `4-execute`, effective condition authority is checked first. `--to` (backward direction) bypasses; `--force` bypasses the marker/condition result only after an idempotent `operator_action` audit is durable. Audit failure prevents the move.
8. **Locking**:
   - `Hive::Lock.with_commit_lock(hive_state_path)` outermost — serialises hive/state writes and surfaces contention BEFORE any filesystem mutation (a 30-second commit-lock timeout never leaves a half-applied move).
   - `Hive::Lock.with_task_lock(task.folder)` inner — blocks a concurrent `hive run` on the same task during the move.
9. For a forward move, build a fresh all-project dependency snapshot and enforce admission inside both locks, after the read-only destination collision check and immediately before `File.rename`. A benign dependency wait raises `DependencyWaitError` (exit 75); an admission error raises `DependencyAdmissionError` (exit 78). `--force` bypasses only step 7's marker check. Backward moves skip admission so corrupt metadata can be repaired by moving to an earlier stage.
10. `move_task!`: direct `File.rename` from source to destination, with a rescue for `Errno::ENOTEMPTY` / `EEXIST` / `EISDIR` that surfaces as `Hive::DestinationCollision`. Cross-device fallback uses `cp_r` + `rm_rf`.
11. Cleanup the moved `.lock`, record the slug-scoped commit, and roll the move back if commit fails.
12. Report human prose or one `hive-approve` JSON document.

## JSON contract (`schema = "hive-approve"`, version 2)

### Success

```json
{
  "schema": "hive-approve",
  "schema_version": 2,
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

The split `from_stage` (bare) + `from_stage_index` + `from_stage_dir` (combined) shape mirrors `hive-run`'s `stage` / `stage_index` so a consumer can compare across schemas without string parsing. `next_action.kind` is drawn from the closed `Hive::Schemas::NextActionKind` enum (`edit`, `mv`, `approve`, `run`, `recover_stale`, `no_op`). `hive run --json` now emits `kind=approve` for `:complete`, `:execute_complete`, and `:review_complete` (was `mv`); the `mv` value is retained in the enum for back-compat.

### Error envelope (every failure path under `--json`)

```json
{
  "schema": "hive-approve",
  "schema_version": 2,
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
- `FinalStageReached` → `stage: "9-done"`
- `DependencyWaitError` → `error_kind: "dependency_wait"`, exit 75, plus `reason_code`, `offending_ref`, `safe_correction`
- `DependencyAdmissionError` → `error_kind: "admission_error"`, exit 78, plus the same structured fields
- `ConditionGateBlocked` → `error_kind: "wrong_stage"`, exit 4, plus the complete `condition_gate` and reason-specific `next_action`

The envelope is emitted on stdout BEFORE the exception propagates, mirroring `hive run --json`'s dual-signal pattern (JSON document + non-zero exit code).

`Hive::Commands::Approve.error_kind_for` is the shared transition-error
classifier. Workflow stage actions delegate to it because their outer envelope
exposes the same closed error-kind enum while composing this command.

Pinned by `Hive::Schemas::SCHEMA_VERSIONS["hive-approve"]` and the command/schema suites. The current artifact is `schemas/hive-approve.v2.json`; v1 remains available for historical validation.

## Slug resolution rules

- **Slug not found**: `Hive::InvalidTaskPath` → exit 64 (USAGE).
- **Slug appears in multiple stages of the same project**: bare resolution raises `Hive::AmbiguousSlug` (64). An absolute folder selects the source, but forward dependency admission still rejects the duplicate qualified identity with `dependency_validation_failed`; repair the duplicate state rather than dispatching through it.
- **Slug appears in multiple projects**: `Hive::AmbiguousSlug` → exit 64 with a hint to pass `--project <name>`.
- **`--project NAME`** scopes the slug lookup to a single registered project. Combining `--project` with an absolute folder path is allowed only if the path's project matches the name; mismatch raises `Hive::InvalidTaskPath`.
- **Bare slug + cwd shadow**: a bare slug is always resolved through the cross-project search even if a directory of the same name exists in `pwd`.

## Marker policy

`Hive::Commands::Approve::VALID_TERMINAL_MARKERS = %i[complete execute_complete review_complete]` — the closed set that gates forward auto-advance. Each marker is written by exactly one stage and unblocks exactly one transition:

| Marker | Written by | Unblocks `hive approve` |
|--------|-----------|-------------------------|
| `:complete`         | inert stages (1-inbox, 2-brainstorm, 3-plan, 7-artifacts, 8-finalize, 9-done) | the next stage in the pipeline (e.g. `2-brainstorm` → `3-plan`) |
| `:execute_complete` | `Stages::Execute` after the implementation phase finalizes | `4-execute` → `5-open-pr` |
| `:review_complete`  | `Stages::Review` after the autonomous loop finalizes | `6-review` → `7-artifacts` |

| Direction | Marker required | Override |
|-----------|-----------------|----------|
| Forward auto (no `--to`) | terminal marker **and clear dependency admission** | `--force` affects marker only |
| Forward via `--to`       | terminal marker **and clear dependency admission** | `--force` affects marker only |
| Backward via `--to`      | none                            | n/a      |
| Same stage (no-op)       | none                            | n/a      |

`:error`, `:waiting`, `:execute_waiting`, `:execute_stale`, `:review_waiting`, `:review_ci_stale`, `:review_stale`, `:review_error` are all non-terminal: they leave the task in place. The error message includes `marker is :<name>` so an agent can branch deterministically. Backward `--to` is the recovery lever (e.g. `hive approve <slug> --to 3-plan` after an execute crash). For the recovery markers (`:review_stale` / `:review_ci_stale` / `:review_error` / `:execute_stale` / `:error`) the agent-callable surface is `hive markers clear FOLDER --name <NAME>` — see [[commands/markers]].

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
| Advancing past `9-done` | 4 (`WRONG_STAGE`) | `Hive::FinalStageReached` |
| Destination already exists | 1 (`GENERIC`) | `Hive::DestinationCollision` |
| Commit failed; mv rolled back | 1 (`GENERIC`) | `Hive::Error` |
| Lock contention (commit lock held >30s) | 75 (`TEMPFAIL`) | `Hive::ConcurrentRunError` |
| Valid prerequisite below its gate | 75 (`TEMPFAIL`) | `Hive::DependencyWaitError` |
| Invalid/indeterminate dependency admission | 78 (`CONFIG`) | `Hive::DependencyAdmissionError` |

## Why not just use `mv`?

Raw `mv` remains possible, but it bypasses supported-command validation. The
next `hive status`, daemon tick, `hive run`, or forward `hive approve` detects
and holds invalid dependency state. Agent callers use `approve` for:
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
