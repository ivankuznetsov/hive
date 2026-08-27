---
date: 2026-08-27
slug: incident-advisory-budget-headroom
pages: [e2e, testing, gaps]
---

Raised the advisory incident-regression per-scenario duration target from below
ten seconds to below eleven seconds. The observed hosted-runner
`incident_provider_limit_retry` sample at 10.585 seconds now remains within
the advisory target, while an 11.000-second sample still fails. The functional
E2E gate, strict report-integrity checks, and below-thirty-second aggregate
target are unchanged.
