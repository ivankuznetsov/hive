---
title: Workflow verbs (brainstorm / plan / develop / pr / archive)
type: command
source: lib/hive/commands/stage_action.rb, lib/hive/workflows.rb
created: 2026-04-26
updated: 2026-04-26
tags: [command, workflow, verbs, stage_action, json]
---

**TLDR**: Five Thor commands that wrap promote-or-run for the five stage transitions. `hive plan <slug> --from 2-brainstorm` either advances the task from 2-brainstorm to 3-plan and runs the plan agent, OR (if the task is already at 3-plan) just runs the plan agent. Same shape for `brainstorm`, `develop`, `pr`, `archive`. Backed by `Hive::Commands::StageAction` and `Hive::Workflows`.

## Usage

```
hive brainstorm <slug>                    # promote 1-inbox → 2-brainstorm, run brainstorm
hive plan <slug>                          # promote 2-brainstorm → 3-plan, run plan
hive develop <slug>                       # promote 3-plan → 4-execute, run execute
hive pr <slug>                            # promote 4-execute → 5-pr, run pr
hive archive <slug>                       # promote 5-pr → 6-done, run done

hive plan <slug> --from 2-brainstorm      # idempotency assertion for retry
hive plan <slug> --project NAME           # multi-project disambiguation
hive plan <slug> --json                   # machine-readable hive-stage-action envelope
```

## Steps performed (`Hive::Commands::StageAction#call`)

1. Resolve TARGET via `Hive::TaskResolver` (path or slug). When `--from` is set, the resolver narrows to that stage.
2. **`--from` retry-after-success rescue**: if the resolver fails with `InvalidTaskPath` AND `--from` was set, re-resolve without `stage_filter` and raise `WrongStage` (4) with the actual stage. Mirrors the pattern in `Hive::Commands::Approve` so a retry after a successful advance returns a meaningful `WRONG_STAGE` instead of "no task folder" (64).
3. **Archive idempotency check**: if the verb is `archive` AND the task is already at `6-done` with `:complete` marker, emit a `noop` payload and return. Without this guard, every `hive archive <slug>` would re-run the Done agent and write a fresh `hive: 6-done/<slug> archived` commit.
4. **At-target branch**: if the task is already at the verb's target stage, just run the stage's agent via `Hive::Commands::Run`. Phase: `ran`.
5. **Wrong-stage guard**: if the task is at neither source nor target, raise `WrongStage` with the verb's expected source/target.
6. **Marker validation**: forward advance requires a terminal marker — currently `:complete`, `:execute_complete`, or `:review_complete` (one per stage that writes a typed terminal marker; the closed set is `StageAction::ADVANCE_VERBS_TO_TERMINAL_MARKERS`). The `brainstorm` verb has `force_source: true` and skips this check (inbox tasks template-default to `:waiting`). Mismatch raises `WrongStage` with a copy-paste retry command. The `:review_complete` entry was added 2026-04-28 — without it, `hive pr --from 5-review` rejected every advance from a clean review with "WrongStage cannot advance ... while marker is :review_complete; finish the current stage first" (the marker IS the terminal marker `5-review` writes; gap was a stale whitelist).
7. **Promote**: call `Hive::Commands::Approve` with `to: target_stage`, `from: current_stage`, and `quiet: @json` so the inner Approve doesn't double-emit.
8. **Run**: call `Hive::Commands::Run` on the new folder, also `quiet: @json`.
9. **Emit**: in JSON mode, emit a single `hive-stage-action` envelope with `phase: "promoted_and_ran"` (or `ran` / `noop`).

## JSON contract (`schema = "hive-stage-action"`, version 1)

### Success

```json
{
  "schema": "hive-stage-action",
  "schema_version": 1,
  "ok": true,
  "verb": "plan",
  "phase": "promoted_and_ran",
  "noop": false,
  "slug": "fix-bug-260424-aaaa",
  "from_stage_dir": "2-brainstorm",
  "to_stage_dir": "3-plan",
  "task_folder": "/home/you/Dev/proj/.hive-state/stages/3-plan/fix-bug-260424-aaaa",
  "marker_after": "waiting",
  "next_action": {
    "key": "needs_input",
    "label": "Needs your input",
    "command": "hive plan fix-bug-260424-aaaa --from 3-plan"
  }
}
```

`phase` enum: `promoted_and_ran` (Approve then Run), `ran` (already at target — Run only), `noop` (archive against already-archived task).

### Error envelope

```json
{
  "schema": "hive-stage-action",
  "schema_version": 1,
  "ok": false,
  "verb": "plan",
  "error_class": "WrongStage",
  "error_kind": "wrong_stage",
  "exit_code": 4,
  "message": "task is at 3-plan but --from expected 2-brainstorm (idempotency check: a prior call may have already advanced this task)"
}
```

`error_kind` enum: `ambiguous_slug`, `destination_collision`, `final_stage`, `wrong_stage`, `rollback_failed`, `invalid_task_path`, `error`.

In JSON mode, the inner Approve and Run are quieted so the envelope is a single parseable document. In text mode, Approve and Run emit their normal prose since that output is intended for humans.

External consumers can validate against `schemas/hive-stage-action.v1.json`; resolve via `Hive::Schemas.schema_path("hive-stage-action")`.

## Idempotency contract

`--from <stage>` is the retry-safety lever. After `hive plan <slug> --from 2-brainstorm` succeeds, the task is at 3-plan. A second invocation with `--from 2-brainstorm`:

- TaskResolver with `stage_filter: "2-brainstorm"` returns 0 hits (task is at 3-plan, not 2-brainstorm).
- The rescue re-resolves without `stage_filter`, finds the task at 3-plan.
- Raises `WrongStage` (exit 4) with message naming the actual stage.

Agents driving the pipeline always pass `--from <expected-current-stage>` so a retry after a network blip surfaces the actual state instead of silently double-advancing.

For `archive` specifically: a second invocation against an already-archived task is a clean no-op (phase: `noop`, exit 0, `next_action.key: archived`) instead of re-running the Done agent.

## Exit codes

| Condition | Exit | Class |
|-----------|------|-------|
| Success | 0 | — |
| Wrong stage / `--from` mismatch / non-terminal marker | 4 (`WRONG_STAGE`) | `Hive::WrongStage` |
| Slug ambiguous / unknown / `--project` mismatch | 64 (`USAGE`) | `Hive::InvalidTaskPath` / `AmbiguousSlug` |
| Destination collision | 1 (`GENERIC`) | `Hive::DestinationCollision` |
| Lock contention | 75 (`TEMPFAIL`) | `Hive::ConcurrentRunError` |
| Internal error | 70 (`SOFTWARE`) | `Hive::InternalError` |

## Backlinks

- [[cli]] · [[commands/run]] · [[commands/approve]] · [[commands/status]]
- [[modules/workflows]] — the verb metadata SSOT
- [[modules/task_action]] — produces the `next_action` block
- [[modules/task_resolver]] — slug-to-task resolution with stage filtering
