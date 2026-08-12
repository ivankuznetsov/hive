# Bound `/answer` requires a warm status snapshot in scenario tests

**Date:** 2026-08-12
**Scope:** bot brainstorm answer scenarios, brainstorm answer coverage

## Change

No production change. The bound-answer work moved `/answer <id|slug>` from
`resolve_numeric_target_slug` (which passed a slug through verbatim) to
`resolve_status_row`, so the command can bind the exact project identity and
refuse cross-project slug ambiguity. That makes a loaded status snapshot a
precondition for `/answer`, not just for `/autofix` and `/details`.

The two brainstorm scenario tests still built their supervisor with a fake
status watcher whose rows never reached the cached snapshot, so `/answer`
replied "Status is still loading — try again in a moment." and every
subsequent free-text message fell through to the idea flow. Both now seed a
`Hive::Bot::StatusWatcher::Row` and call `status_tick` before the command,
mirroring what the real bot's status loop does on start.

## Evidence

`s1_brainstorm` asserted four recorded answers and observed `[nil, nil, nil,
nil]`; `s6_voice_idea` never wrote the spoken transcript. Because `/answer`
bailed out early, these scenarios had stopped exercising the bound answer
path end to end — the same gap that left 25 lines of the answer command,
writer, parser, markers, and supervisor uncovered under the 100% line gate.
Seeding the snapshot restored 4 supervisor lines; focused tests cover the
rest: non-integer ordinals, unlocatable Q lines, `create: false` ENOENT,
undecodable v1 escape payloads, the oversized-answer cap, deleted
brainstorm.md, lock-time ENOENT, relocated-but-answered conflict and
idempotent arms, unknown writer results, canonical and unresolvable path
invocations, wrapped internal errors, and the `same_task_path?` fail-closed
guard.

## Remaining gap

`/answer` inherits the snapshot-warmup window from `latest_status_rows`: for
the brief period before the first successful tick, an operator gets the
"still loading" reply rather than a queued command. That is deliberate — see
[[modules/bot]] on why no synchronous fetch happens on the poll thread — but
it is now reachable from `/answer` as well.
