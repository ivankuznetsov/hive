---
date: 2026-09-25
title: One-shot readiness and ownership review repairs
tags: [daemon, one-shot, modules, patrol, scheduling]
---

- Dispatch one-shots now reject missing project observations and reflect the
  actual enablement, legacy-layout, retry, cooldown, and capacity gates in
  readiness without mutating persisted cooldowns during dry-run.
- Module readiness includes pending setup and event work, retrying runs, and
  recurring schedule deadlines. Normal daemons scope module dispatch and
  baseline persistence to the projects whose execution guards they own.
- Malformed dispatch checkpoint rows fail with `checkpoint_invalid`, and
  Architecture Patrol preserves classification retry and claim deadlines
  before records become runnable.
- One-shot command errors remain single, schema-valid documents; aggregate
  inputs are fully schema-validated, per-project babysitter construction
  failures are contained, and interruptions fail closed while preserving
  completed-work evidence.
- Architecture intake uses the configured merge-poll cadence and one absolute
  report/checkpoint deadline. Babysitter dry-run observes real PR check state
  and shares its outcome classification with normal execution.
