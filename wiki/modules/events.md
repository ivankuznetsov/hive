---
title: Hive::Events
type: module
source: lib/hive/events.rb
created: 2026-05-23
updated: 2026-07-26
tags: [module, events, observability, status, append-only]
---

**TLDR**: One append-only task-local journal serves two explicit contracts.
`Hive::Events.emit` remains best-effort telemetry plus the derived `status.md`
renderer; `Hive::TaskJournal::Writer` is the strict, fsynced authoritative path
for versioned condition/generation/evidence/audit records. See
[[modules/conditions]].

## Event types (`Hive::Events::EVENT_TYPES`)

| Type | Producer | When |
|------|----------|------|
| `stage_enter` | `Stages::Base.with_stage_events` (wraps `runner.call` in `Commands::Run`) | Top of every stage run |
| `stage_exit` | same | Bottom of every stage run, including rescue paths (paired closing event) |
| `agent_start` | `Hive::Agent#run!`; also `Stages::Review#mark_working` for phase brackets | Just before `spawn_and_wait` / before each `review_working` mark |
| `agent_end` | same, in `ensure` | Always emitted, even on exception (`status=exception` carries the error class) |
| `error` | `Stages::Base.with_stage_events` rescue path; `emit_marker_event` for error markers | Stage raised, or marker landed on `:error` / `:review_error` / `:review_ci_stale` / `:review_stale` |
| `round_waiting` | `Stages::Base.emit_marker_event` | Brainstorm or plan stage closed with `:waiting` marker |
| `round_complete` | same | Brainstorm or plan stage closed with `:complete` marker |

`ROUND_EVENT_STAGES = %w[brainstorm plan]` is the registry that gates round events — adding a new stage that publishes `:waiting` / `:complete` round markers requires extending this list so `emit_marker_event` stays in sync with the producers.

## Durable module events are separate

`Hive::Modules::EventLedger` is the strict, project-local launch ledger. It is
separate from the fail-soft `Hive::Events` telemetry described below. Its v1
vocabulary is intentionally closed to `task.completed`,
`pull_request.merged`, and `project.registered`; schedules use the same
dispatcher but are represented as explicit scheduled occurrences.

Each persisted occurrence binds immutable project identity, occurrence and
recording time, source identity, event id, idempotency key, and a canonical
payload digest. Re-delivery with the same identity and payload returns the
existing occurrence; conflicting reuse fails closed. Every hook evaluation is
paired with a `Hive::Modules::DecisionJournal` launch or skip receipt, including
generation/configuration/grant identity and the linked attempt when admitted.
The daemon is the sole autonomous dispatcher. The ledger maintains a canonical
event-id and latest-schedule index, while the daemon durably advances an event
offset after each fully evaluated occurrence. Idle ticks therefore do not
reparse retained event or decision histories; an absent or crash-stale index is
rebuilt from the immutable event files before use.

Legacy registry rows derive the same deterministic project UUID during
read-time projection and daemon persistence, so events written before backfill
do not become foreign afterward. Every successful evidence-closure terminal
path publishes `task.completed`; archive no-op redelivery derives its
occurrence time from the unchanged task state file, keeping the canonical
payload stable under the same idempotency key. Decision-journal readers cache
the parsed immutable history behind a directory signature and invalidate on
another writer, avoiding a full history parse for every event/module/hook
tuple without hiding cross-process appends.

## Record shape

```json
{"ts":"2026-05-23T08:12:44Z","slug":"my-task-260523-1a2b","stage":"4-execute","agent":"claude execute","event_type":"agent_start","message":"cwd=/abs/path/to/worktree-foo timeout_sec=3600 max_budget_usd=10"}
```

- `ts` — ISO-8601 UTC, second precision.
- `slug` / `stage` — task slug and `<index>-<name>` stage label.
- `agent` — `"<profile> <log_label>"` for agent spawns (e.g. `"claude review-stub-reviewer-pass01"`); `"phase=<name> pass=<NN>"` for review phase brackets; `null` for stage / round / error events.
- `event_type` — one of the table above.
- `message` — short human-readable detail. `agent_start` carries `cwd=<full @cwd path> timeout_sec=N max_budget_usd=N` (full path, not basename — basename collapsed the worktree-vs-task-folder distinction); `agent_end` carries `status=… exit_code=… pid=…` (or `status=exception` with the error class); `stage_exit` carries `status=<marker> phase=… reason=… pass=…` when those marker attrs are present.

## Storage and atomicity

The legacy rules below describe `Hive::Events.emit`. Authoritative
`hive-task-journal-event` records use a separate writer: a per-task flock,
validated stable event envelope, one complete batch write, flush/fsync, and a
surfaced exception on any failure. `Events.emit` rejects authoritative event
types so a swallowed telemetry error cannot be mistaken for gate state. The
contracts also use separate files: fail-soft operational telemetry stays in
`events.jsonl`, while strict condition authority lives in
`task-journal.jsonl`. Neither reader has to negotiate mixed unversioned shapes.

- **Path**: `<task_folder>/events.jsonl` (one file per task slug, lives next to `task.md`).
- **Append**: single `File.write` of `JSON.generate(record) + "\n"` opened `O_WRONLY | O_APPEND | O_CREAT`. Records stay well under `PIPE_BUF` (~4 KiB), so POSIX append-atomicity holds across concurrent emitters; the single-write contract is load-bearing and must not be split into "write JSON then write newline."
- **Failure mode**: `SystemCallError` during emit is caught and warned to stderr (`[hive.events] failed to emit ...`). The producing stage / agent control flow is not interrupted — observability must never mask the underlying run result.

## Derived `status.md`

After every successful append, `render_status!` rewrites `<task>/status.md` to a fixed layout:

```
# Status: <slug>
Stage:         <stage>
Updated:       <ts of last event>
Last event:    <event_type> — <message>
Current agent: <topmost open agent>

## Recent events (last 20)
- 2026-05-23T08:12:44Z  agent_start  claude execute  cwd=…
- …
```

- **Tail window**: last `STATUS_TAIL_LINES = 20` parseable records.
- **Current-agent recovery**: walks `CURRENT_AGENT_WALK_LINES = 200` trailing records (a wider window than the 20-event tail) and replays `agent_start` / `agent_end` as a stack so a long-running agent whose start scrolled past the recent-events tail still renders honestly as `Current agent: …` rather than em-dash.
- **Read budget**: only the last `STATUS_TAIL_BYTES = 16 KiB` of `events.jsonl` is read on each emit. Records average ~140 bytes, so the 16 KiB window fits ≥100 records — comfortably more than the 200-line walk window. Keeps emit sub-millisecond on long-lived tasks.
- **Atomic write**: writes a uniquely-named `.status.md.tmp.<pid>.<tid>.<hex>` sibling, `fsync` (best-effort — `EINVAL` / `ENOSYS` / `IOError` are swallowed because some filesystems don't support fsync on regular files), then `File.rename` over the target. Concurrent emitters never observe a half-written file. The temp filename includes `Process.pid`, `Thread.current.object_id`, and 4 random hex bytes so two emit paths running in the same process from different threads don't collide on the temp name.

## Torn-record tolerance

`read_recent_events` parses each line with `JSON.parse` and **skips unparseable lines silently**. Two cases this handles:

1. The leading edge of the 16 KiB read window almost always slices through a record — the first line is dropped when the read offset is non-zero.
2. A concurrent emitter that has issued its `write(JSON + "\n")` but whose newline has not yet become visible on a particular filesystem (rare but possible). Skipping the torn line preserves the rest of the tail rather than blowing up the renderer.

`emit` itself is single-write atomic, so the file is never *corrupted*; the parser just declines to interpret partially-visible records.

## Bracket discipline

The system contract is that every `stage_enter` has a matching `stage_exit`, and every `agent_start` has a matching `agent_end`. Three places enforce this:

1. **`Stages::Base.with_stage_events`** wraps `runner.call` and catches `SystemExit` + `StandardError` to emit a paired `error` + `stage_exit` before re-raising. Without the trailing `stage_exit` on failure paths, drill-down readers would observe permanently-open stage brackets after any crash.
2. **`Hive::Agent#run!`** emits `agent_start` before `spawn_and_wait` and `agent_end` in `ensure`. The exception branch records `status=exception` and the error class.
3. **`Stages::Review#mark_working`** opens a phase-level `agent_start` (agent label `phase=<name> pass=<NN>`) and stores it in `@open_phase_event`. Each subsequent `mark_working` closes the previously-open phase first, and an `ensure` in `Review.run!` closes whatever is still open when the runner exits — guaranteeing balanced brackets across every exit path (return, raise, `SystemExit`).

Per-reviewer spawns inside Phase 2 emit their own `agent_start` / `agent_end` via `Hive::Agent#run!` and use the profile-name + `log_label` form (`"claude review-stub-reviewer-pass01"`) so they're visually distinct from the phase-level pair (`"phase=reviewers pass=01"`) and nest cleanly under it in drill-down views.

## SyntheticTask awareness

`Hive::Agent` is invoked on both real `Hive::Task` instances (stage-runner-owned spawns: 4-execute, brainstorm, plan, open-pr) and `Hive::Reviewers::SyntheticTask` shims (Phase 2 reviewers, Phase 3 triage, Phase 1 CI-fix, Phase 5 browser-test). `SyntheticTask` is a `Struct` that intentionally omits `slug` / `stage_index` and stores the full `"6-review"` label in `stage_name`. `Agent#event_slug` and `Agent#event_stage` use `respond_to?` to derive the right values from either shape — there is no separate code path per task class.

## Tests

- `test/unit/events_test.rb` — emit happy path, validation, atomic rename, torn-record skipping, 16 KiB tail window, current-agent stack across the 200-line walk, status body rendering.
- `test/unit/agent_test.rb` — agent_start / agent_end pairs on success and exception paths, slug / stage derivation from `SyntheticTask`.
- `test/integration/run_brainstorm_test.rb`, `run_plan_test.rb`, `run_review_test.rb` — end-to-end bracket balance through `Commands::Run`.
- `test/integration/status_test.rb` — `status.json` JSON contract preserved after events instrumentation rolled out.

## Backlinks

- [[modules/agent]] · [[modules/stages]] · [[modules/markers]]
- [[stages/brainstorm]] · [[stages/plan]] · [[stages/review]]
- [[commands/run]] · [[commands/status]]
