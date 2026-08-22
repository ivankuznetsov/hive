---
title: Patrol Fix integrated lifecycle and supervised semantic admission
type: change
date: 2026-08-21
tags: [patrol, architecture-patrol, workflow, daemon, qualification, dogfood]
---

- Bound semantic admission to the complete Patrol Fix-owned task inventory and
  one deterministic, evidence-rich top-64 context rather than an unbounded scan
  of every task directory.
- Moved the single semantic provider launch into the existing daemon child
  supervisor with a durable leased reservation, exact completion fencing,
  restart recovery, timeout handling, and standard workflow concurrency.
- Added fake-provider lifecycle proof for both discovery sources, cross-source
  duplicate convergence, rework, separately parked escalation, publication,
  and replay without duplicate tasks or PRs.
- Added a frozen historical four-gate qualification corpus and a strict
  observation-only dogfood report schema. No real provider, GitHub mutation,
  hosted CI, or natural-finding dogfood ran as part of this change.
