---
title: Distinguish local Patrol transition generations
type: fixed
date: 2026-08-04
---

- Keep semantic target/scope duplicate detection for externally observable
  Patrol effects.
- Key local Architecture Patrol `job`, `discovery`, and `action` JobStore
  transitions by exact intent and idempotency identity, allowing a fenced
  recovery generation to repeat a local target/scope without failing
  qualification as a duplicate effect.
