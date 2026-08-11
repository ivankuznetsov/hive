---
title: Freeze routing identity in durable attempt v4
type: change
date: 2026-08-10
---

**Changed:** Durable attempts now use schema v4 with a required legacy or
explicit routing identity. Explicit records freeze the policy digest, decision,
provider-account route, enclosing circuit generations, probe bindings, and a
receipt-versioned sanitized provider-evidence field without reinterpreting the
existing adapter/profile `provider` field.

**Durability:** The default store moves to `$HIVE_HOME/attempts/v4`. The
forward-only migration converts valid schema-v3 hot records and immutable
proofs to legacy-mode v4 records, preserves malformed hot bytes as capacity
reservations, rejects malformed proofs, publishes v2/v3 old-binary fences, and
has crash/restart coverage around per-record conversion.

**Policy ownership:** Explicit task-generation policies use an owner-private,
point-addressed, first-writer-wins `ProviderRouting::PolicyStore`. Legacy mode
performs no policy-store I/O. Authenticated attempt context exposes only the
route already persisted at admission.
