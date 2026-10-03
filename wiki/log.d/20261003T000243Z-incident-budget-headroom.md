---
date: 2026-10-03
slug: incident-budget-headroom
pages: [e2e, testing, gaps]
---

Restored the advisory incident aggregate target from below 32 seconds to below
36 seconds after a healthy hosted run reached 32.511 seconds. The three
individual incidents remained below their 16-second targets, and the functional
E2E job passed. Regression coverage now includes the observed hosted durations
and continues to reject an aggregate of exactly 36 seconds.
