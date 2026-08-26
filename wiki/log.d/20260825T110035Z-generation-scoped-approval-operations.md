---
title: Scope durable approval operations to one task lifecycle visit
type: fix
date: 2026-08-25
---

**Problem:** A workflow rework could return a task to a stage transition that
had already completed. `hive approve` reused the route-only operation ID, so
the retained receipt from the earlier ownership generation conflicted with the
new attempt and the daemon retried the same failed transition indefinitely.

**Action:** Approval and rejection operation IDs are now bounded deterministic
digests of the transition route, numeric task input epoch, and opaque ownership
generation. Retries inside one lifecycle visit remain idempotent, while a
legitimate revisit creates a separate durable operation receipt. Added focused
coverage for stable same-ownership identity, a real completed-receipt revisit,
distinct rework identity, and the operation-ID size limit.
