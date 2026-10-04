---
date: 2026-10-04
slug: incident-budget-headroom
pages: [e2e, testing, gaps]
---

Restored the advisory incident aggregate target from below 32 seconds to below
36 seconds after healthy hosted runs on `main` and this pull request reached
32.342 and 32.392 seconds. Every individual incident remained below its
16-second target, and the functional E2E jobs passed. Regression coverage now
includes the observed pull-request durations and continues to reject an
aggregate of exactly 36 seconds.
