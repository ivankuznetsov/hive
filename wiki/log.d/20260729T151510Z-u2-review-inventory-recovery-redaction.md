---
title: Bound Patrol inventory work and redact durable effect outcomes
type: change
created: 2026-07-29
tags: [patrol, architecture-patrol, recovery, performance, secrets]
---

- Full `BoundedFileInventory` traversals now take one bounded sorted filename
  snapshot instead of rescanning the directory once per page; stateless cursor
  pages retain high-water fingerprint validation.
- Occurrence journal state now carries a monotonic dirty generation. Reservation
  marks it before writing product work, and only a generation-matched empty
  repair clears it, so crashes and concurrent reservations remain recoverable
  while later idle scheduler ticks skip retained terminal history.
- `EffectDelivery` recursively redacts every nested string in terminal outcomes
  before settlement or denial reaches a product store. Journal receipts,
  projected evidence, shadow comparison, and terminal replay therefore share
  the same redacted canonical bytes while preserving objects, arrays, numbers,
  booleans, and nulls.
- Focused proofs cover one enumeration at the 4,096-entry limit, retained
  terminal history, a reservation racing a clean repair, and a fake GitHub
  token absent from journal, evidence, comparison, and replay.
