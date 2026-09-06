---
date: 2026-09-06
slug: incident-isolation-budget-headroom
pages: [e2e, testing, gaps]
---

Raised the advisory incident-regression per-scenario ceiling from below eleven
seconds to below sixteen seconds after the Git-isolation change. The
`incident_provider_limit_retry` semantic scenario passed in two hosted runs at
13.424s and 14.031s and locally at 15.871s; its new boundary test preserves the
strict less-than comparison. The functional E2E integrity gate and the
below-thirty-second aggregate budget remain unchanged. More hosted samples are
still needed before treating sixteen seconds as a stable p95.
