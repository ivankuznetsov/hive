---
title: Keep task workspace evidence current after activity writes
date: 2026-08-14
---

`Hive::TaskActivity` now refreshes the bounded task-projection checkpoint after
every successful authoritative append. The journal remains lifecycle authority,
and a checkpoint refresh failure cannot invalidate an already-durable activity;
it only keeps Hive Web mutation controls fail-closed until a later repair.

The real-browser golden-path provider fixture now emits the same minimal
structured usage evidence expected from a real Claude run, so the test proves
question answering with current status, attempt, and resource evidence rather
than bypassing the workspace safety gate.

Workspace fallback paths now call the module-owned unavailable-panel builder,
reject non-object activity payloads with a typed validation error, and preserve
the cursor from a valid bounded snapshot while reporting degraded projection
diagnostics. Local publication ancestry also treats the only two admitted Git
exit statuses as ancestor or divergent, removing an unreachable fallback.
