---
title: Patrol captures and effect gateways
type: change
created: 2026-07-28
tags: [patrol, architecture-patrol, modules, migration, evidence]
---

- Ordinary scheduler reservations now persist an immutable occurrence capture
  and publish that exact identity to the module adapter; module cron targets
  are suppressed until the module owns mutation.
- Architecture Patrol keeps merged-PR enqueue provenance and publishes a
  linked finalized capture only after the authoritative JobStore outcome.
- Separate ordinary and architecture gateways hold migration admission across
  live owner/config/capability checks and mutation sinks. StateStore,
  JobStore, ReviewHandoff, and Safe Agent Git Gate remain recovery owners;
  append-only evidence is never consulted for retry.
- Shadow-decision v1 files migrate once into archived non-comparable records;
  runtime comparison accepts only the structured v2 contract.
