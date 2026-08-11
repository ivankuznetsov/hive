# Bound provider-health active journals

Provider Health now rotates a valid active journal before the event or byte
ceiling can reject a mutation permanently. Rotation archives verified events,
persists their idempotency receipts, snapshots the exact circuit without a
generation or epoch change, and atomically starts a bounded active journal.
Restart, duplicate evidence, live probes, operator blocks, and later mutations
retain their prior semantics.
