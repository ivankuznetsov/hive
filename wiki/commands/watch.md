---
title: hive watch
type: command
source: lib/hive/commands/watch.rb, lib/hive/operational_status.rb, lib/hive/commands/status.rb
created: 2026-07-20
updated: 2026-07-20
tags: [command, watch, agents, status, jsonl, observability]
---

**TLDR**: `hive watch` is a bounded, read-only semantic observer for agents.
It resolves selected tasks once from one complete status graph, emits an
initial event and only meaningful transitions, then emits a final event on the
requested terminal condition, timeout, event cap, interruption, or source
failure. It replaces shell polling loops; machine mode is JSON Lines.

## Usage

```bash
hive watch PROJECT:SLUG
hive watch SLUG --project PROJECT
hive watch --project PROJECT
hive watch PROJECT:ONE PROJECT:TWO --until completion
hive watch PROJECT:SLUG --json-lines --interval 15 --timeout 1800 --max-events 100
```

Targets are either exact `PROJECT:SLUG` identities or bare slugs. A bare slug
must resolve uniquely, with `--project` available to disambiguate. With no
positional targets, `--project` selects that project's active tasks. Selection
is resolved exactly once from a full `hive-status` graph and is capped at 100
tasks. The watch pins the selected task id when one is available, so a later
task that reuses the same `PROJECT:SLUG` cannot replace it in the stream; the
original task must either remain present, appear in the verified archive, or
be reported missing. An initially id-less task is provisionally pinned by its
directory device/inode identity. If the daemon backfills an id onto that same
directory, the watch adopts and then pins the new id; it does not confuse the
repair with task replacement. If active/archive materialization exposes
multiple physical rows for the selected identity, including an id-less
active/archive collision, selection refuses the collision and reports the
distinct row type, stage, and folder alternatives instead of silently
collapsing them. If an id-less task's physical identity cannot be established,
selection fails closed before starting the stream.

Defaults are `--interval 15`, `--timeout 1800`, `--max-events 100`, and
`--until settled`. Interval/timeout must be positive finite numbers and the
event cap a positive integer. The normal global `--json` document flag is
rejected because watch is a stream; use `--json-lines`.

## Events

Each line is one `hive-watch-event.v1` document in JSON Lines mode. The event
types are:

- `initial` — the selected targets at observation start.
- `transition` — at least one selected target's semantic projection changed.
- `source_warning` — a poll failed or a selected task disappeared without
  verified archival. This is not treated as completion.
- `final` — always emitted after the last retained state, even when the
  non-final event cap has been reached.

Events include sequence, timestamp, reason/message, selected count, and the
complete selected target array. A target carries exact identity, presence and
archive flags, operational state, blocker owner/reason codes, stage/marker,
provider name/retry time when known, scheduler freshness, liveness,
terminality, and the safe action-policy summary when present. The semantic
fingerprint is computed from this bounded target shape, so unchanged polling
does not produce heartbeat noise.

`--until settled` stops when every selected task is `waiting_on_you`,
`needs_repair`, `completion_ready`, or verified archived. `--until completion`
stops only when every target is verified archived. A row disappearing from
both active and verified archive views emits warnings; three consecutive
misses fail as `status_unavailable` rather than fabricating success.

## Termination and exits

Timeout and event-cap finals are bounded successful observations, not task
success claims. The overall timeout bounds every status-source fetch, physical
identity resolution, and poll sleep, so neither a blocked source nor task-path
lookup can overrun the requested deadline or publish a late transition. A
source's own timeout exception still counts against the source-failure budget;
only Hive's private overall-deadline interrupt produces a successful `timeout`
final. A
same-identity row collision discovered after selection counts as a source
failure rather than choosing one row. Three consecutive source failures emit a final
`status_unavailable` event and fail the command. `SIGINT` and `SIGTERM` emit a
final `interrupted`/`terminated` event and exit 130/143. A closed downstream
pipe is handled cleanly. Initial selection/source errors fail before a useful
stream can start.

The command never writes task state, claims a task lock, dispatches a stage,
or calls a model. To execute a routine action, obtain the descriptor from a
fresh `hive status --operational --json` snapshot and use `hive act`.

## Tests

- `test/unit/commands/watch_test.rb` covers target resolution, ambiguity,
  task-id pinning across slug reuse, verified id backfill, physical-row
  collisions and their repair evidence, project selection, bounds, transition
  deduplication, settled/completion termination, archive verification,
  disappearance/source failure budgets, source/identity deadlines,
  timeout/event caps, signals, EPIPE, JSON Lines, and read-only behavior.
- `test/e2e/scenarios/watch_semantic_transitions.yml` pins the subprocess
  scenario contract.

## Backlinks

- [[cli]] · [[commands]] · [[commands/status]] · [[modules/daemon]]
