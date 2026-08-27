---
date: 2026-08-27
slug: patrol-publication-secret-park
---

- Changed Patrol Fix secret-policy publication failures from repeated failed
  attempts into a sanitized, generation-scoped `publication_block` receipt and
  operator-owned parked outcome before any remote effect.
- Added the exact receipt-bound `patrol_fix.rework_publication` operational
  action. It advances a new generation to Inbox, Fix, or Review under the
  controller and task locks; daemon policy does not dispatch it and ordinary
  `workflow.retry` cannot release the park.
- The rework executor now verifies the exact task-lock owner and releases that
  same lock at the moved destination, so the operator action cannot strand a
  live-lock artifact after changing stages.
