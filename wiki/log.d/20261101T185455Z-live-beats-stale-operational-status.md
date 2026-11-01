---
title: Prefer live flags in operational status
date: 2026-11-01
tags: [operational-status, liveness, status, regression]
---

- Either true liveness flag now outranks stale evidence in operational state,
  ownership, liveness reasons, and liveness status. Material scheduler reasons
  still precede the live explanation; stale-only rows need repair when their
  action is `agent_running` or marker is `agent_working` or `review_working`.
- `tasks[].liveness.pid` now publishes only an available PID whose liveness
  flag is true, preferring the lock PID, then the agent PID, otherwise null.
  Lock checks match process start time when recorded; agent checks test PID
  existence only and can accept a reused PID.
  Stale-only rows now publish null instead of a historical PID, changing field
  semantics without changing the schema.
- Added mixed-direction regressions for a live lock with a stale agent PID and
  a live agent with a stale lock (a synthetic projector invariant), including
  scheduler ordering, PID provenance, missing PIDs, and unverified flags.
- Focused projector and operational-command tests pass; projected cases validate
  against the published schema, and changed-source line coverage is exactly 100%.
