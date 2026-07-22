---
title: Condition journal review hardening
date: 2026-07-17
tags: [conditions, journal, projection, status, review]
---

- Reused one authoritative-record validator for journal writes and projection
  replay, including exact schema-version and durable attempt task/stage/input-
  epoch/ownership checks; forged and future-version records now fail closed.
- Made authoritative appends retry short writes and roll back to the prior
  fsynced byte boundary when a later write or sync fails.
- Separated strict `task-journal.jsonl` authority from fail-soft
  `events.jsonl` telemetry, and made even binding-matched projection snapshots
  revalidate their journal's durable attempt identity.
- Preserved published `hive-attempt` v1 and `hive-status` v5, moved the new
  wire shapes to v2 and v6, and kept the compatibility lock's
  `task_generation` field as the opaque owner token.
- Isolated `project_load_failed` per project so one bad projection cannot
  masquerade as a healthy empty project or erase healthy sibling rows.
- Wired terminal/lost execute attempt reconciliation into idempotent
  `AgentHealthy` journal observations, and made research waivers derive from
  persisted file evidence rather than caller booleans.
- Added fault-injection, replay, fixture, snapshot, and status regressions for
  the hardened boundaries.
- Added a bounded valid-snapshot path that hashes journal bytes and validates
  each unique current/predecessor attempt once; changed bindings still take a
  full parse/replay. Terminal observer deliveries are memoized per daemon
  process, while durable restart idempotency remains journal-backed.
- Made predecessor lineage causal authority: missing/incompatible/cyclic links
  fail closed and a clock-regressed successor still supersedes its predecessor.
  Terminal/lost durable state also reconciles current `AgentHealthy` before the
  daemon observer lands.
- Missing/empty post-handoff journals now fail both read and rebuild without
  overwriting the last snapshot. Marker-only proof is scoped to attempt-stamped
  `execute_*` markers so review and other stage markers do not falsely claim an
  execute condition-journal handoff. First-create retries fsync the task
  directory.
- Added condition-specific recovery actions and structured blocked-transition
  error envelopes. Forced condition overrides must durably append an
  idempotent `operator_action`; status exposes the latest 20 overrides while
  the journal retains their complete history.
