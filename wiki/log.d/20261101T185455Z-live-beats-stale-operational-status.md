---
title: Prefer verified live evidence in operational status
date: 2026-11-01
tags: [operational-status, liveness, status, regression]
---

- Either verified-live signal now outranks stale evidence in operational state,
  ownership, liveness reasons, and liveness status. Material scheduler reasons
  still precede the live explanation; purely stale runners still need repair.
- `tasks[].liveness.pid` now publishes only an available verified-live PID,
  preferring the live lock PID, then the live agent PID, otherwise null.
  Stale-only rows now publish null instead of a historical PID, changing field
  semantics without changing the schema.
- Added mixed-direction regressions for a live lock with a stale agent PID and
  a live agent with a stale lock (a synthetic projector invariant), including
  scheduler ordering, PID provenance, missing PIDs, and unverified flags.
- Focused projector and operational-command tests pass; projected cases validate
  against the published schema, and changed-source line coverage is exactly 100%.
