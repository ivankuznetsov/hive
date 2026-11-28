---
title: Workflow verbs
type: command
source: lib/hive/cli.rb, lib/hive/commands/stage_action.rb, lib/hive/task_closure.rb, lib/hive/task_closure_result.rb, lib/hive/commands/adhoc_review.rb, lib/hive/workflows.rb, lib/hive/gh.rb
created: 2026-04-26
updated: 2026-11-22
tags: [command, workflow, verbs, stage_action, json, closure, evidence]
---

> **Public CLI authority:** See [docs/cli.md](../../docs/cli.md#day-to-day-workflow) for canonical invocation syntax, options, JSON schemas, context rules, and exit codes. This page documents internal implementation, storage, and architecture.

**TLDR**: Eight Thor commands wrap promote-or-run for the stage transitions defined in `Hive::Workflows::VERBS`: `brainstorm`, `plan`, `develop`, `open-pr`, `review`, `artifacts`, `finalize`, and `archive <target>`. The CLI also gives `hive archive` a no-target listing mode and an interactive, evidence-bound `already_delivered` / `superseded` closure mode. Ordinary archive safety is unchanged: only `Hive::TaskClosure` can invoke the internal guarded-archive protocol (`Hive::Commands::GuardedArchive`) that retires an active task from outside its workflow's ordinary terminal transition. Automatic same-repository merge closure uses that same protocol; there is no marker-reason archive bypass.

## CLI overlays

No-target `hive archive` is a CLI overlay in `Hive::CLI#archive`: when `target.nil?`, it constructs `Hive::Commands::Status.new(json: options[:json], archive: true)` and returns before `StageAction` is involved. Only `hive archive <target>` uses the promote-or-run workflow semantics below.

`hive review --pr PR` is a CLI overlay in `Hive::CLI#review`. `PR` accepts a bare number, `#number`, or a GitHub `/pull/number` URL; bare positional `hive review 197` is unchanged and still resolves task id `197`. The overlay uses `Hive::Commands::AdhocReview` to resolve the registered project from the current directory or `--project NAME`, fetch PR metadata through `Hive::Gh.pr_metadata`, create/reuse `6-review/adhoc-review-pr-N/`, refuse if another Hive task already owns that PR, and materialize the PR head at the normal worktree root through `Hive::Worktree.materialize_pr`. After the task exists it calls `StageAction.new("review", slug, project:, json:)`, so a fresh ad-hoc task is already at the review stage and emits normal `phase: "ran"` text/JSON behavior.

## Evidence-bound delivered closure

`--reason`, `--evidence`, `--successor`, or `--attestation` selects
`Hive::TaskClosure`, not ordinary StageAction. Verification prints one
normalized preview and a digest bound to the current task/marker generation,
registered repository identity, immutable GitHub facts, live owner state, and
owned-worktree safety. A failing preview never archives. A passing one asks
`Archive <slug> as <reason>? [y/N]`; `--yes` confirms without the prompt (for
scripts and agents), and without a terminal or `--yes` the closure fails closed.
The earlier `CLOSE <digest-prefix>` phrase
was removed on 2026-10-27. Confirmation re-reads every mutable fact before
writing `closure.json`.

### Closure JSON

With `--json`, stdout is exactly one document, and `--yes` picks the mode:

| Invocation | Document | Meaning |
|---|---|---|
| `--json` | `hive-task-closure-input.v1` plus `mode: "preview"`, `applied: false`, `next` | Read-only. Nothing is archived. `ok` only says the preview is valid. `next` is the shell-quoted `--yes --json` command that applies this exact closure, or `null` while the preview has errors or blockers. |
| `--json --yes` | `hive-task-closure-result.v1` with `ok: true`, `mode: "apply"`, `applied: true` | The task was archived. Carries `reason`, `task`, `preview_digest`, `receipt_digest`, and the full `receipt`. |
| any failure | `hive-task-closure-result.v1` error arm, `ok: false`, `mode` | Closed `error_kind` (`Hive::TaskClosureResult::ERROR_KINDS`). A blocked `--yes` run includes the failed `preview`. bin/hive still prints `hive: <message>` on stderr and exits with the error's code. |

Before 2026-11-19, `--json --yes` printed only the preview (`ok: true`) and
exited without archiving, while the same command without `--json` archived. An
agent read `ok: true` as an archived task. `--json` without `--yes` is still a
preview, so existing preview readers see the same fields plus the three
additive ones. `Hive::TaskClosureResult` (`lib/hive/task_closure_result.rb`)
builds all three shapes. `--idempotency-key` now works with `--json --yes`: the
keyed `CommandOperation` result, including `command_receipt` inside `receipt`,
is reported as the result document. A keyed `--json` preview is still refused
as a usage error, because a read-only preview has nothing to key.

`already_delivered` requires at least one same-repository merged PR or full
commit OID that is reachable from the repository default branch.
An owned worktree may still contain commits after a squash merge: closure
accepts it when the clean worktree HEAD is exactly the verified merged PR head
or a local Git ancestor of that head. A different or unverifiable unique HEAD
continues to block closure.
`superseded` requires exactly one registered `project:slug` successor and a
non-empty operator attestation; its authority is always
`operator_attestation`. `--evidence` is optional for it. When given, the
evidence is verified exactly as for `already_delivered`, except that
cross-repository evidence is accepted; unverifiable evidence fails the preview
and never falls back to the successor alone. Equal refs, a clean branch,
similar titles, a merely closed PR, and shortened SHAs are never delivery
proof.

Without `--evidence` (added 2026-11-22), the registered successor task is the
supersession proof: the closed task is linked to the task that replaces it,
and nothing was delivered. That closure follows the cancellation path: it binds
the registered local checkout (`task_repository: {path}`, no GitHub access),
records `evidence: []`, skips the owned-worktree delivery blockers so the
worktree and branch stay for the successor, moves to the terminal stage
without the terminal runner (`COMPLETE outcome=superseded`), and does not
satisfy dependents: admission reports `dependency_validation_failed` telling
them to depend on the successor instead. The receipt records the resolved
successor (`project`, `slug`, `id`, `stage`). A successor that is the task
itself, unresolvable, cancelled, itself superseded without delivery (which
also refuses supersession cycles), or carrying an unreadable closure receipt
is refused; an active successor or one archived with delivery qualifies.

`cancelled` retires unwanted work without claiming delivery. It requires a
non-empty operator reason, accepts neither evidence nor a successor, and needs
no GitHub access. It checks the registered local project and refuses live task
owners or attempts. Missing dependencies do not prevent cancellation. Dirty
worktrees, branches, task artifacts, journals, and token history are retained.
The existing receipt/confirmation protocol moves the task to its workflow's
terminal stage without running a terminal agent, cleanup, or completion hook.
Marker-based workflows record `COMPLETE outcome=cancelled`; controller-owned
inert terminals retain their manifest unchanged. A cancelled prerequisite does
not count as delivered: dependents must remove or replace that dependency.
An invalid closure receipt blocks dependency admission, including after another
consumer quarantines it. Admission reads closure evidence without moving it.
The Web archive form and bot `/close` accept the same reasons; both show the
resolved successor of a supersession, and `/close --reason superseded`
requires `--successor` but not `--evidence`.

The receipt is written atomically before transition. Its exact digest enters a
separate `TransitionGuard.validate_closure!` path; it is not attempt success
evidence and cannot weaken the ordinary marker/condition guard. `Hive::TaskClosure`
then drives the one internal guarded-archive protocol, `Hive::Commands::GuardedArchive`,
which may force the task from any active stage to the terminal stage declared by
that task's workflow (`9-done` for coding and `6-done` for content or Patrol Fix),
run an agent-owned terminal stage with the internal no-rebase override, and
retain `closure.json`. A controller-owned inert terminal such as Patrol Fix
has no terminal agent: its valid closure receipt authorizes only the move to
that workflow's terminal stage, and that receipt remains the completion
authority instead of synthesizing a publication receipt or marker. StageAction
itself carries no closure branch: it dispatches only ordinary verb transitions,
while GuardedArchive holds no receipt semantics — the caller injects the
pre-transition guard (rechecked inside the atomic move lock) and an optional
locked-task observation. The immutable
delivery evidence has already settled the feature branch, while Done only
writes the terminal marker and cleanup instructions, so replaying stale branch
commits cannot affect closure and must not dispatch conflict-resolution agents.
A crash after receipt write resumes through the same no-rebase path;
an already-completed transition is a no-op. Corrupt, unsupported, stale, or
identity-mismatched receipts are quarantined and never authorize a move.

## Steps performed (`Hive::Commands::StageAction#call`)

1. Resolve TARGET via `Hive::TaskResolver` (path or slug). When `--from` is set, the resolver narrows to that stage.
2. **`--from` retry-after-success rescue**: if the resolver fails with `InvalidTaskPath` AND `--from` was set, re-resolve without `stage_filter` and raise `WrongStage` (4) with the actual stage. Mirrors the pattern in `Hive::Commands::Approve` so a retry after a successful advance returns a meaningful `WRONG_STAGE` instead of "no task folder" (64).
3. **Evidence-closure dispatch**: none. StageAction has no closure-specific branch or entrypoint; `Hive::TaskClosure` drives `Hive::Commands::GuardedArchive` directly with its injected receipt guard.
4. **Archive idempotency check**: if the verb is `archive` AND the task is already at `9-done` with `:complete` marker, emit a `noop` payload and return.
5. **At-target branch**: if the task is already at the verb's target stage, just run the stage's agent via `Hive::Commands::Run`. Phase: `ran`.
6. **Wrong-stage guard**: if the task is at neither source nor target, raise `WrongStage` with the verb's expected source/target.
7. **Marker/condition validation**: forward advance requires a terminal marker — currently `:complete`, `:execute_complete`, or `:review_complete` (one per stage that writes a typed terminal marker; the closed set is `Hive::Markers::TERMINAL_MARKER_NAMES`). Effective condition authority additionally gates `4-execute`; a blocked JSON error includes `condition_gate` and `next_action`. The `brainstorm` verb has `force_source: true` and skips this check. Archive has no error-marker exception; automatic merge closure reaches the separate receipt guard only through `Hive::TaskClosure`.
8. **Archive merge confirmation** (`confirm_archive_pr_merged!`): for the
   ordinary `archive` advance out of `8-finalize`, a finalize `:complete`
   marker only proves the PR was readied. StageAction reads the canonical
   `pr_url` from `pr.md` and asks GitHub through `Hive::Gh.pr_state` (the same
   adapter finalize's merged short-circuit uses) whether it is `MERGED`. Any
   other answer refuses before the move with `Hive::ArchivePrNotMerged`
   (`reason=pr_not_merged`, message names the PR URL and state); a gh failure
   or a missing/non-canonical `pr_url` fails closed with
   `Hive::ArchivePrStateUnobservable` (`reason=pr_state_unobservable` /
   `pr_url_unresolved`). Both are `WrongStage` subclasses: exit `4`, JSON
   `error_kind: wrong_stage`, distinguished by `error_class`, with
   `current_stage`/`target_stage`. The message names the two ways forward:
   merge the PR and re-run `hive archive <slug> --from 8-finalize`, or close
   with `--reason already_delivered|superseded|cancelled`. Explicit `--reason`
   closures never reach this guard (they use `Hive::TaskClosure`), and the
   daemon's merged-PR reconciliation keeps its own closure receipt path.
9. **Promote**: call `Hive::Commands::Approve` with `to: target_stage`, `from: current_stage`, and `quiet: @json` so the inner Approve doesn't double-emit.
10. **Run**: call `Hive::Commands::Run` on the new folder, also `quiet: @json`.
11. **Emit**: in JSON mode, inner Approve and Run are quieted so a single `hive-stage-action` envelope is emitted; transition errors are classified through `Hive::Commands::Approve.error_kind_for` so direct approve and stage actions stay aligned.

## Idempotency contract

`--from <stage>` is the retry-safety lever. After `hive plan <slug> --from 2-brainstorm` succeeds, the task is at 3-plan. A second invocation with `--from 2-brainstorm`:

- TaskResolver with `stage_filter: "2-brainstorm"` returns 0 hits (task is at 3-plan, not 2-brainstorm).
- The rescue re-resolves without `stage_filter`, finds the task at 3-plan.
- Raises `WrongStage` (exit 4) with message naming the actual stage.

Agents driving the pipeline always pass `--from <expected-current-stage>` so a retry after a network blip surfaces the actual state instead of silently double-advancing.

For `archive` specifically: a second invocation against an already-archived task is a clean no-op (phase: `noop`, exit 0, `next_action.key: archived`) instead of re-running the Done agent.

## Backlinks

- [[cli]] · [[commands/run]] · [[commands/approve]] · [[commands/status]]
- [[modules/workflows]] — the verb metadata SSOT
- [[modules/task_action]] — produces the `next_action` block
- [[modules/task_resolver]] — slug-to-task resolution with stage filtering
