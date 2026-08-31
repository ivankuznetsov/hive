---
title: Markerless controller retries use fresh delivery identities
date: 2026-08-31
tags: [daemon, recovery, attempts, idempotency]
---

**Problem:** A controller workflow keeps the same task generation when a
worker exits without changing its structured state. The recovery coordinator
rearmed the same dispatch request after cooldown, but attempt admission treats
a request id as immutable delivery identity and correctly replayed its first
failed receipt. Every scheduled retry therefore replayed old evidence and no
new worker could heal the task.

**Action:** A terminal markerless recovery now writes a deterministic fresh
delivery request for the next retry count, copies its bounded recovery ledger,
and removes the superseded terminal queue receipt. The immutable attempt proof
is retained. Duplicate observation before terminalization still returns the
same request, and repeated failures still stop at the existing deterministic
failure ceiling. The obsolete whole-queue fallback in the startup-only claimed
receipt repair was removed; that repair now requires its already-known claimed
path and remains directory-bound.

**Evidence:** Recovery coordinator tests prove a terminal controller failure
rearms as one new pending delivery, removes the old claimed receipt and claim
sidecar, preserves the retry count, and never mutates the controller manifest.
Attempts tests continue to prove that a new recovery request can launch a fresh
attempt while replaying the same request remains idempotent. Queue tests cover
the path-bound repair and its missing-directory failure mode.
