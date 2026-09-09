---
title: Simplify the SQLite attempt runtime
date: 2026-09-04
---

**Change:** Replaced retained provider health, policy, circuit, audit, probe,
attempt-lineage, result-outbox, allowance, and maintenance-checkpoint state with
current-configuration routing, independent attempt rows, request-row delivery
state, token-usage reservations, and daemon-local bounded maintenance. Removed
the `hive circuits` command and its schemas because there is no provider state
left to inspect or mutate.

**Why:** SQLite is the sole machine-local coordination authority, but it should
not make transient routing decisions or one-to-one attempt facts into separate
durable subsystems. The smaller model preserves token history and crash-safe
admission/delivery while deriving live capacity and provider rotation from
current facts.

**Operational effect:** Existing pre-release SQLite databases must be rebuilt
through the irreversible fleet cutover. Pending bot results survive restarts
until acknowledged; external delivery remains at-least-once across a
send-before-ack crash. Patrol daily limits are derived from unique token-usage
session rows, and only the daemon runs attempt maintenance.

**Review hardening:** Final attempts now remain visible until archive and
failure-cohort promotion is durably marked. Lost-attempt dirty captures are
sealed and transactionally linked to the independent replacement, so retention
cannot invalidate inherited output. Attempt maintenance is bounded by both row
count and monotonic elapsed time. The canonical and OpenClaw Hive guidance now
describes stateless routing instead of the removed circuits command.
