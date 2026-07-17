---
title: Generation-scoped execute task conditions
date: 2026-07-17
tags: [conditions, projection, journal, execute, status]
---

- Added a strict, fsynced authoritative record path to task-local
  `task-journal.jsonl`, reusing durable attempt identity and adding numeric task and
  commit generations without rewriting legacy attempts.
- Added the seven-condition registry, typed evidence, pure supersession
  projection, cursor/hash-bound atomic snapshots, versioned execute policy,
  marker/shadow/conditions authority, legacy baseline, and parity audit.
- Routed execute reconciliation, completion, and forward transition guards
  through journal → snapshot → gate → compatibility marker ordering.
- Put the canonical projection under TaskAction/status and passed the additive
  condition contract through daemon, TUI, bot, and web consumers.
- Added a reusable incident replay harness plus sanitized task-1849 fixture,
  operator rollout/repair/rollback documentation, and an explicit live-shadow
  evidence gap.
