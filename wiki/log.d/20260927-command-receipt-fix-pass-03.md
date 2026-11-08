---
date: 2026-09-27
title: Close command receipt replay and lifecycle gaps
---

- Preserve exact JSON replay bytes and caller-selected display mode, and make
  pre-submission contention safely reacquirable without treating applied path
  failures as whole-effect non-application.
- Fence dispatch contexts by receipt ownership, charge their storage, keep
  caller pins until durable acknowledgement, and retain active successor-cycle
  bindings during prune.
- Validate success and error envelopes, the extension version ledger, and
  indexed maintenance/reclamation paths while keeping public previews behind
  read-only inspection.
- Persist relocation audit context across marker-write crashes and publish the
  installation capacity, staffing, maintenance, and recovery contracts.
