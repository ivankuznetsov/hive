---
title: Close one-shot review pass 02 lifecycle gaps
tags: [daemon, one-shot, babysitter, modules, scheduling]
---

- Separated daemon project ownership from enablement so explicit recovery
  requests cannot bypass a concurrent one-shot owner.
- Made dispatch one-shots reconcile module run completion after attempt drain,
  report accepted durable queue work in `ran`, and turn merge-observation
  failures or exceptions into non-authoritative error results.
- Made babysitter one-shots observe PRs beyond repair capacity, retain per-PR
  GitHub errors, and keep observation-only dry-runs free of event/status writes.
- Bounded Patrol and Architecture Patrol child execution with a wall-clock
  timeout and TERM-to-KILL escalation.
