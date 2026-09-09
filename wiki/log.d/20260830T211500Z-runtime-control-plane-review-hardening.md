---
title: Harden irreversible runtime activation after adversarial review
date: 2026-08-30
tags: [runtime-control-plane, sqlite, cutover, payloads, json, review]
---

The irreversible cutover now journals service shutdown before it begins,
validates every retired path and the complete SQLite candidate before fencing,
rechecks task authority at intent, holds legacy token usage against late writers,
publishes active database authority only after idempotent service activation,
and uses single-link atomic phase manifests. Database custody requires private owned
SQLite/WAL/SHM files and exact normalized schema DDL.

Dispatch claims now bind the explicit attempt id and typed task identity.
Terminal and lost attempts atomically move their request to
`awaiting_delivery`: it remains replayable until delivery completes but no
longer blocks a retry or successor, while active-subject uniqueness still
covers queued, claimed, and admitted requests. Sequel datasets never escape
the fork checkout. Shared content-addressed payload publication and expiry now
hold the same digest custody lock, closing the last-reference unlink race.

Finalization maintenance now claims its hourly pass in an immediate SQLite
transaction and persists its cold-sweep cursor, result, and error. Independent
foreground or daemon processes therefore share one schedule and continue the
same bounded scan instead of each restarting it from page one.

The process guard strongly retains each connected database wrapper until that
wrapper disconnects. A wrapper that loses its last caller reference therefore
cannot disappear from the fork barrier while sqlite3 still owns a writable
handle; process-wide shutdown and test isolation close every registered pool.

Adversarial review also closed shared-database disconnects, deterministic
sequence promotion, typed recovery scans, stale task-observation overwrites,
payload-expiry retry gaps, duplicate task identity redirects, and legacy
writer/fence races. Runtime status exposes resumable `ready` and `intended`
phases with an exact next action while ordinary commands remain activation
gated.

Runtime maintenance JSON is versioned as `hive-runtime-maintenance.v1`, including
errors emitted by the pre-CLI activation gate. The published operational-status
v4 storage shape is preserved. Bounded running status is now
`hive-running-status.v2`; its counters name SQL lease rows instead of retired
filesystem entries. Canonical and OpenClaw Hive skills describe the
operator-approved, forward-only recovery path and explicitly reject invented
rollback, restore, or downgrade actions.
