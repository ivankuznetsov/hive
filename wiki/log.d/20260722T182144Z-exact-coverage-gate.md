---
date: 2026-07-22
slug: exact-coverage-gate
pages: [testing]
---

Made the default 100% line-coverage gate compare exact covered and executable
line counts instead of trusting the rounded display percentage. A report with
54,789 covered lines out of 54,790 now fails even though its displayed value is
`100.00%`, and the failure reports the honest `54789/54790` numerator and
denominator. Configured thresholds below 100% retain percentage comparison
semantics. Updated [[testing]] with the distinction; did not edit compiled
[[log]].
