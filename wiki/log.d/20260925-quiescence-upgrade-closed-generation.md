# 2026-09-25 — Preserve closed generations during quiescence upgrade

- `RuntimeControlPlane::QuiescenceUpgrade` now recognizes only the pinned
  pre-quiescence layout and the two explicitly tested quiescence-era schema
  fingerprints introduced by the lifecycle and process-inventory increments.
- Quiescence-era conversion requires a `quiescing` or `paused` source and
  preserves installation, attempt, payload, generation, deadline, and
  interrupted-attempt evidence while advancing migration revision/sequence and
  leaving admission closed in `quiescing`.
- Conversion still runs only through the supervised Ruby API. It revalidates
  the fingerprint under operation/writer fences, invalidates the old proof
  before schema writes, checks foreign keys, and verifies byte-identical current
  initializer DDL. Unknown or reopened sources are rejected without writes.
