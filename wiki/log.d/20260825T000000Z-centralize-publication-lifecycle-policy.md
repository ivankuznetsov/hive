---
title: Centralize publication attempt lifecycle policy in PublicationAttempt
date: 2026-08-26
---

- `Hive::RefactorPatrol::PublicationAttempt` is now the single owner of the
  publication phase-append lifecycle grammar. New pure interface:
  `phase_order_violation`, `well_ordered?`, `phase_operation`, and
  `phase_payload_keys` backed by the `PHASE_OPERATIONS` and
  `PHASE_PAYLOAD_KEYS` constants; legacy operation-to-phase mapping is derived
  from `PHASE_OPERATIONS`.
- `JobRecordValidator.validate_publication_phase!` and
  `validate_publication_receipts!` consume that interface instead of
  maintaining a second phase grammar, operation mapping, and an independent
  copy of the "PR-create intent requires durable push completion" rule.
  Validation behavior is unchanged; stored attempts must remain well ordered.
