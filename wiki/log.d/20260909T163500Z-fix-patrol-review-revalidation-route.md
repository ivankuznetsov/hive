---
date: 2026-09-09
slug: fix-patrol-review-revalidation-route
---

- Corrected the Patrol Fix `revalidate` route-intent shape: a stale validation
  detected during Review returns from Review to Validate, rather than claiming
  Publish as its source stage. Focused review-stage coverage now exercises the
  generation rotation and retained receipts through the real transition.
