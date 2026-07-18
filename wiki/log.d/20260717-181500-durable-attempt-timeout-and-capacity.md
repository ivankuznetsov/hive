---
date: 2026-07-17
summary: Keep durable attempt timeouts, drains, and capacity fail-closed
---

- Wired foreground and daemon durable-attempt launchers to resolve the exact
  Hive verb's `daemon.child_verb_timeouts` fallback and configured
  `child_kill_grace_sec` from the fresh global daemon config.
- Made `ConfiguredDispatcher` derive global, per-project, and daily limits from
  each fresh global config load, while project config still supplies lease
  timers, so raised caps and timeout settings apply to the next initial attempt
  or loss successor without a daemon restart.
- Kept supervisor heartbeat and timeout enforcement active after the worker
  leader exits. Descendants that retain stdout/stderr now receive bounded
  TERM/KILL cleanup and cannot strand the wrapper waiting forever for EOF.
- Kept lost attempts with a recorded worker capacity-reserving until durable
  cleanup proves `absent`, `terminated`, or `no_worker`; missing, corrupt, or
  unsafe/manual cleanup evidence remains fail-closed.
