---
title: U2 Patrol effect recovery resolution
type: change
created: 2026-07-28
tags: [patrol, architecture-patrol, migration, recovery, evidence]
---

- Added one canonical occurrence journal beneath the separate StateStore and
  JobStore product APIs. It atomically binds sender leases, dispatch
  uncertainty, terminal outcomes, canonical receipt/capture/event outbox
  bytes, and projection acknowledgement.
- Routed ordinary mutation sinks and Architecture Patrol job, discovery,
  action, GitHub, and review-handoff transitions through their product
  gateways. Removed the ordinary effect maps and ActionRunner's run-global
  effect correlation.
- Kept those boundaries small by composition: both product gateways delegate
  to separate admission, sender, and receipt-projection collaborators; the
  occurrence facade delegates to a pure validator, one store owner, outbox, and
  effect state machine. ActionRunner and the scheduler delegate durable
  transition orchestration to claim/plan/discovery/occurrence collaborators.
  Command and daemon intake share one manifest coordinator; a separate
  immutable binding stores only the architecture job-to-occurrence identity.
- Expired uncertain deliveries are reconciliation-only. Exact absence must be
  durable before a fresh sender CAS, while exact terminal duplicates replay
  the original receipt bytes.
- Finalized positive and negative ordinary captures and one job-bound
  architecture occurrence now feed comparison. Evidence reads use bounded
  occurrence/intent indices with restart-safe bounded repair pages and never
  participate in recovery.
- The one-off shadow-decision migration is resumable, quiescence-fenced, and
  v2-only at runtime. Patrol Effect Evidence remains a catalog candidate until
  U3 supplies compressed candidate-bound qualification proof.
