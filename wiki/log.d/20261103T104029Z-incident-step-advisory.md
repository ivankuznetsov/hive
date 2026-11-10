---
date: 2026-11-03
slug: incident-step-advisory
pages: [e2e, testing, gaps]
---

Moved incident-duration `continue-on-error` from the job to the timing step,
matching the absolute TUI latency advisory. Timing overruns remain visible in
the step log and a new job summary while the check finishes successfully for
exact-head CI consumers. Functional E2E, report integrity, and the sixteen-second
per-scenario/thirty-six-second aggregate limits remain unchanged. Strengthened
the existing workflow contract test and exercised summaries for timing success,
overruns, and skipped measurements.
