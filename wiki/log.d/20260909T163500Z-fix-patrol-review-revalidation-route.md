---
date: 2026-09-09
slug: fix-patrol-review-revalidation-route
---

- Corrected the Patrol Fix `revalidate` route-intent shape: stale validation
  detected during either Review or Publish returns from that active stage to
  Validate. Focused stage coverage exercises the generation rotation and
  retained receipts through both real transitions.
