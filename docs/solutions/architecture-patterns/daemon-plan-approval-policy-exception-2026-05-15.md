---
title: Daemon plan-approval policy exception — auto-dispatch plan WAITING rows for daemon-enabled projects
date: 2026-05-15
category: architecture-patterns
module: Hive::Daemon
problem_type: architecture_pattern
component: dispatcher
severity: high
applies_when:
  - Building a background dispatcher that classifies status rows into dispatch decisions
  - A subset of "WAITING" states are actually "approval pauses" (durable consent already given out-of-band) rather than Q&A waits requiring user input
  - The dispatcher must satisfy a downstream "terminal-marker gate" that refuses to advance while a WAITING marker is in place
  - The same dispatch decision is also surfaced through a manual UI (TUI, CLI) which already handles the case correctly
tags:
  - daemon
  - dispatcher
  - policy
  - state-machine
  - hive-pipeline
  - marker-flip
  - workflow-verb
  - approval-pause
---

# Daemon plan-approval policy exception

## Context

`Hive::Daemon` (ADR-024) auto-advances tasks through the pipeline so an operator-enabled project marches `inbox → brainstorm → plan → execute → review → open-pr → finalize → done` without per-stage approval gestures. The daemon's source of truth is `hive status --json` — each task row carries an `action` field (`ready_to_*`, `needs_input`, etc.) and a `suggested_command` populated by `Hive::TaskAction`. `Hive::Daemon::Policy.decide` classifies each row into one of `:dispatch / :poll_for_merge / :wait_for_debounce / :record_baseline / :skip`.

Originally `Policy.decide` treated every `needs_input` row identically: apply an mtime baseline + debounce so the daemon dispatches only after the operator visibly edits the state file. This makes sense for brainstorm answers, execute questions, and review decisions — all are Q&A waits where the agent needs typed input. But it produced a stuck-state bug for plan-stage rows.

## Symptom

A generated plan would sit in `3-plan` with `<!-- WAITING -->` and TUI status "Needs your input" indefinitely. The daemon log showed `event: skipped` every 30s with `in_flight: 0`. Manually running `hive run --json` on the row flipped the marker to `<!-- COMPLETE -->`, after which the daemon immediately dispatched `hive develop ... --from 3-plan` on its next tick.

Symptom signature for future debugging:
- `hive status --json` reports the row as `stage: "3-plan", action: "needs_input", marker: "waiting"`
- The state file's mtime is days-old
- Daemon log shows continuous `event: skipped` with no `event: dispatched`
- Operator did nothing wrong — they generated a plan, expected the daemon to take it forward

## Root cause

`plan_waiting` semantically isn't a Q&A wait. The plan stage emits `<!-- WAITING -->` when the plan document is ready for human review, not because the agent needs typed input. In the manual TUI flow, the operator reads `plan.md`, decides "yes ship this", and presses `d` (develop) — the TUI then transparently flips the marker `:waiting → :complete` and dispatches `hive develop`. For daemon-enabled projects, the durable consent is `daemon.enabled: true` (set at `hive init`); the operator's "yes ship this" was given when they enrolled the project. There is no per-task approval gesture needed.

The Policy treating every `needs_input` row uniformly meant the daemon waited forever for an operator gesture that, by the project's own consent model, was already given.

## Fix

Two coupled changes, both required:

1. **Carve out `plan_approval?` in `Policy.decide`.** The predicate matches `action == "needs_input" && stage == "3-plan"` (literal stage equality — `Hive::Stages::DIRS` is a closed enum with exactly one plan stage). When true, `Policy.decide` returns `:dispatch` directly, bypassing the mtime debounce. Other `needs_input` stages (brainstorm/execute/review) keep the existing edit-resume path.

2. **`Hive::Daemon::PlanApproval.prepare`** at dispatch time. The row's `suggested_command` is `hive plan ... --from 3-plan` (per `TaskAction`, which is correct for the manual TUI's `p` re-run flow but wrong for daemon auto-advance). The dispatcher cannot just dispatch the raw command — it would re-run the plan stage, leaving the marker at `:waiting`, producing a 60s-cadence re-dispatch loop. The fix is to:
   - Rewrite the command: `hive plan ...` → `hive develop ...` via Shellwords round-trip.
   - Flip the marker `:waiting → :complete` via `Hive::Markers.set`. This is required so the workflow verb's terminal-marker gate (`Hive::Commands::Approve::VALID_TERMINAL_MARKERS = %i[complete execute_complete review_complete]`) accepts the advance — `hive develop --from 3-plan` against a `:waiting` marker raises `Hive::WrongStage` (exit 4) and the daemon would loop on the gate refusal instead of the agent re-run.

**Load-bearing ordering:** validate the command shape BEFORE flipping the marker. If a malformed `suggested_command` is dispatched and the marker has already been flipped to `:complete`, the row strands at "approved" with no follow-up dispatch — operationally worse than the original loop because the operator sees a green-looking row that never moves. `PlanApproval.prepare` raises `ArgumentError` on a malformed command without touching the marker; `Dispatcher` routes the row to `:skipped reason: "plan_approval_invalid"` and the marker stays at `:waiting` for inspection.

## Why this composes with the TUI's pattern

The TUI's `BubbleModel#dispatch_develop_for` / `#develop_command_from_plan` / `#finalize_plan_marker` already implements exactly the same two-step pattern for its `:advance_to_develop` keybinding (diagnosed in `i-want-to-be-able-260507-7682` / `now-we-run-claude-codex-260508-3b8f` bug reports). The daemon fix EXTRACTS this pattern into a callable module (`Hive::Daemon::PlanApproval`) rather than duplicating it inline. The TUI's helper stays scoped to its message layer; the daemon's helper is callable from outside the TUI. Same load-bearing invariants in both places (validate command before flipping marker, raise on non-`:waiting`/`:complete` markers).

If a future surface (CLI verb, MCP tool, webhook) ever needs the same advance-plan-as-daemon-eligible behavior, it should call `Hive::Daemon::PlanApproval.prepare` and not re-derive the logic.

## Logging contract

`Dispatcher#dispatch_command` emits `:dispatched` with a `trigger:` field set to `"plan_approval"` (vs `"advance"` for `ready_to_*` actions). An operator or agent reading `daemon.log` can distinguish plan-approval auto-advances from regular advance-action dispatches without re-implementing `Policy.decide`. The Logger validates event NAME against a closed enum but per-event fields are open (`**attrs`), so adding `trigger:` is non-breaking for consumers.

## Testing

The bug was masked in the original PR's dispatcher test because it stubbed `command: "hive develop slug --from 3-plan"` — the production string would have been `"hive plan slug --from 3-plan"`. Test rewritten to:
- Create a real tmpfile with `<!-- WAITING -->` marker
- Pass the production `hive plan ...` string as `suggested_command`
- Assert the spawned command is the rewritten `hive develop ...` form
- Assert the marker on disk is `:complete` after the tick
- Assert `:dispatched` event fired with `trigger: "plan_approval"`

Plus dedicated `test/unit/daemon/plan_approval_test.rb` (10 cases) covers every branch of `PlanApproval.prepare` and `.rewrite_to_develop` directly so a refactor breaking one arm surfaces in the focused file rather than in noisier dispatcher tests.

**General lesson on test mocks:** when a unit test stubs a value the production code computes through another module, the test passes regardless of whether the producer matches. Whenever feasible, drive the test through the real producer (here: real `TaskAction#command` output) or assert the producer's output matches the stub in a separate test. The PR-#83 mask cost a full review cycle to surface.

## Negative cases (do NOT auto-approve)

`plan_approval?` is deliberately narrow:

- Triage WAITING (`6-review` / `:review_waiting`) requires the user to tick `[x]` on findings — a genuine Q&A gate. Do NOT extend the carve-out here.
- Brainstorm WAITING (`2-brainstorm` / `:waiting`) holds questions the brainstorm agent asked. Daemon must wait for typed answers; mtime debounce stays.
- Execute WAITING (`4-execute` / `:execute_waiting`) is the agent asking the user something or surfacing a recoverable state. Same — keep debounce.

The asymmetry is genuine: only plan WAITING represents a finished artefact waiting for an approval signal that the daemon's enrollment already gave.

## Related solutions

- `docs/solutions/architecture-patterns/background-spawn-and-signal-aware-marker-healing-2026-04-28.md` — supervisor-not-owner pattern. Establishes the precedent that a specific marker signature can be treated as "automation can resolve this without a human touching the file." Plan-approval is the same shape applied at the Policy level.
- ADR-024 in `wiki/decisions.md` — daemon automation-first; the gate is "user input required." The plan-approval exception is ADR-024 amended: plan WAITING is NOT a user-input gate when consent is given out-of-band via `daemon.enabled: true`.
