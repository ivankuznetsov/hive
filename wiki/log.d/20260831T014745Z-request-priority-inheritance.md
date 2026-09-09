---
title: Request FIFO inherits suffix priority during cross-source arbitration
date: 2026-08-31
tags: [daemon, scheduler, fairness, dispatch-queue, priority-inversion]
---

**Problem:** Cross-source arbitration compared direct task rows only with the
current FIFO request. A blocked low-rank request at the queue head could
therefore let medium-priority direct rows repeatedly consume capacity while a
later high-stage recovery request remained invisible.

**Action:** Precompute a suffix maximum of request priorities and inherit that
priority backward through the FIFO prefix when comparing the request lane with
direct rows. Requests still execute chronologically; priority inheritance only
prevents unrelated rows from entering ahead of the higher-priority suffix.

**Evidence:** Dispatcher regressions cover an eligible FIFO head, a blocked
unknown-project recovery ahead of a later high-stage request, and the suffix
boundary after that high-priority request. With one slot, the eligible head
still launches first; when the head is blocked, the later request launches
instead of the intervening direct row; a low-priority tail does not inherit an
earlier peak.
