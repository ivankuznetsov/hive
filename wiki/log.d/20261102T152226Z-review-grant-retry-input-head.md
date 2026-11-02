# 2026-11-02 — Retain granted-slot input HEAD across fix retries

- Share the validated granted-slot input HEAD across immediate guardrail
  scans, sealed completion receipts and subsequent failure records. Failed
  attempts that committed guarded changes remain subject to approval even
  after a successful no-op retry or a restart before guardrail admission.
- Cover guarded commit → provider failure → no-op retry, restart recovery,
  and later slots retaining their own input rather than an earlier slot's
  proof. Reject missing input HEADs in matching resume evidence.

Pages: [[stages/review]], [[gaps]].
