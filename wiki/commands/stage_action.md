---
title: Workflow verbs
type: command
source: lib/hive/cli.rb, lib/hive/commands/stage_action.rb, lib/hive/commands/adhoc_review.rb, lib/hive/workflows.rb, lib/hive/gh.rb
created: 2026-04-26
updated: 2026-06-29
tags: [command, workflow, verbs, stage_action, json]
---

**TLDR**: Eight Thor commands wrap promote-or-run for the stage transitions defined in `Hive::Workflows::VERBS`: `brainstorm`, `plan`, `develop`, `open-pr`, `review`, `artifacts`, `finalize`, and `archive <target>`. The CLI also gives `hive archive` a no-target listing mode that delegates to [[commands/status]] archive mode instead of `StageAction`; a daemon-only archive recovery flag can retire two whitelisted `8-finalize` error markers after GitHub reports the PR as merged. `hive review --pr PR` is the workflow-verb overlay for ad-hoc review: it creates or reuses an ad-hoc `6-review` task, then calls the same StageAction review path for the generated slug.

## Usage

```
hive brainstorm <slug>                    # promote 1-inbox → 2-brainstorm, run brainstorm
hive plan <slug>                          # promote 2-brainstorm → 3-plan, run plan
hive develop <slug>                       # promote 3-plan → 4-execute, run develop
hive open-pr <slug>                       # promote 4-execute → 5-open-pr, open draft PR
hive review <slug>                        # promote 5-open-pr → 6-review, run review
hive review --pr 197                      # create/reuse 6-review/adhoc-review-pr-197, run review
hive artifacts <slug>                     # promote 6-review → 7-artifacts, collect artifacts
hive finalize <slug>                      # promote 7-artifacts → 8-finalize, finalize PR
hive archive <slug>                       # promote 8-finalize → 9-done, run archive
hive archive                              # list every 9-done task via Status archive mode
hive archive --json                       # hive-status payload filtered to 9-done rows

hive plan <slug> --from 2-brainstorm      # idempotency assertion for retry
hive plan <slug> --project NAME           # multi-project disambiguation
hive plan <slug> --json                   # machine-readable hive-stage-action envelope
```

No-target `hive archive` is a CLI overlay in `Hive::CLI#archive`: when `target.nil?`, it constructs `Hive::Commands::Status.new(json: options[:json], archive: true)` and returns before `StageAction` is involved. Only `hive archive <target>` uses the promote-or-run workflow semantics below.

`hive review --pr PR` is a CLI overlay in `Hive::CLI#review`. `PR` accepts a bare number, `#number`, or a GitHub `/pull/number` URL; bare positional `hive review 197` is unchanged and still resolves task id `197`. The overlay uses `Hive::Commands::AdhocReview` to resolve the registered project from the current directory or `--project NAME`, fetch PR metadata through `Hive::Gh.pr_metadata`, create/reuse `6-review/adhoc-review-pr-N/`, refuse if another Hive task already owns that PR, and materialize the PR head at the normal worktree root through `Hive::Worktree.materialize_pr`. After the task exists it calls `StageAction.new("review", slug, project:, json:)`, so a fresh ad-hoc task is already at the review stage and emits normal `phase: "ran"` text/JSON behavior.

`hive archive TARGET --recover-merged-error-reason REASON` is internal daemon plumbing, not an operator workflow. `Hive::Daemon::PrMergeWatcher` appends it only after polling `gh pr view --json state` and seeing `MERGED` for a task that is still at `8-finalize` with one of the whitelisted stale-local-error reasons. `StageAction` re-checks the current marker and GitHub state before accepting it.

## Steps performed (`Hive::Commands::StageAction#call`)

1. Resolve TARGET via `Hive::TaskResolver` (path or slug). When `--from` is set, the resolver narrows to that stage.
2. **`--from` retry-after-success rescue**: if the resolver fails with `InvalidTaskPath` AND `--from` was set, re-resolve without `stage_filter` and raise `WrongStage` (4) with the actual stage. Mirrors the pattern in `Hive::Commands::Approve` so a retry after a successful advance returns a meaningful `WRONG_STAGE` instead of "no task folder" (64).
3. **Archive idempotency check**: if the verb is `archive` AND the task is already at `9-done` with `:complete` marker, emit a `noop` payload and return.
4. **At-target branch**: if the task is already at the verb's target stage, just run the stage's agent via `Hive::Commands::Run`. Phase: `ran`.
5. **Wrong-stage guard**: if the task is at neither source nor target, raise `WrongStage` with the verb's expected source/target.
6. **Marker validation**: forward advance requires a terminal marker — currently `:complete`, `:execute_complete`, or `:review_complete` (one per stage that writes a typed terminal marker; the closed set is `Hive::Markers::TERMINAL_MARKER_NAMES`). The `brainstorm` verb has `force_source: true` and skips this check. `archive` has one additional internal exception: a matching `--recover-merged-error-reason` accepts an `8-finalize` `ERROR` marker only when the current `reason=` equals the flag, `pr.md` contains a `pr_url`, and `Hive::Gh.pr_state(pr_url)` returns `MERGED`.
7. **Promote**: call `Hive::Commands::Approve` with `to: target_stage`, `from: current_stage`, and `quiet: @json` so the inner Approve doesn't double-emit.
8. **Run**: call `Hive::Commands::Run` on the new folder, also `quiet: @json`.
9. **Emit**: in JSON mode, emit a single `hive-stage-action` envelope with `phase: "promoted_and_ran"` (or `ran` / `noop`).

## JSON contract (`schema = "hive-stage-action"`, version 2)

### Success

```json
{
  "schema": "hive-stage-action",
  "schema_version": 2,
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
  "schema_version": 2,
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

External consumers can validate the current contract through `Hive::Schemas.schema_path("hive-stage-action")`, which resolves to `schemas/hive-stage-action.v2.json`; `schemas/hive-stage-action.v1.json` remains in tree for pinned legacy consumers.

## Idempotency contract

`--from <stage>` is the retry-safety lever. After `hive plan <slug> --from 2-brainstorm` succeeds, the task is at 3-plan. A second invocation with `--from 2-brainstorm`:

- TaskResolver with `stage_filter: "2-brainstorm"` returns 0 hits (task is at 3-plan, not 2-brainstorm).
- The rescue re-resolves without `stage_filter`, finds the task at 3-plan.
- Raises `WrongStage` (exit 4) with message naming the actual stage.

Agents driving the pipeline always pass `--from <expected-current-stage>` so a retry after a network blip surfaces the actual state instead of silently double-advancing.

For `archive` specifically: a second invocation against an already-archived task is a clean no-op (phase: `noop`, exit 0, `next_action.key: archived`) instead of re-running the Done agent.

## Merged-Error Archive Recovery

This path exists for an already-merged PR whose local finalize worktree is no longer healthy enough to rerun finalize. The daemon can enqueue it for `git_status_failed` or `claude_launch_failed` finalize errors after `PrMergeWatcher` observes the PR as `MERGED`.

The archive command still refuses the advance when any guard differs from the observed row: the task must still be in `8-finalize`, the marker must still be `ERROR`, the marker's `reason=` must exactly match the internal flag, `pr.md` must still carry a URL, and a fresh `gh pr view <url> --json state` call must still return `MERGED`. If any guard fails, `StageAction` falls back to the normal wrong-stage/non-terminal-marker error path.

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
