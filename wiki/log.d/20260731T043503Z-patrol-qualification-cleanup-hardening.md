---
title: Harden Patrol qualification candidate cleanup
type: change
created: 2026-07-31
tags: [patrol, qualification, e2e, cleanup, security]
---

- Candidate staging and harness workspaces now use non-forced removal and
  require an exact-root absence postcondition.
- Harness cleanup retains no-follow directory descriptors, verifies identity
  and containment before and after descriptor-only directory permission
  repair, and never changes regular-file modes.
- The candidate workspace is removed immediately after repository import,
  before lane execution or publication. Combined preparation and cleanup
  failures preserve the full primary-error cause chain.
- Focused regressions cover no-op removal, inode substitution, preparation
  failure cleanup, cleanup-before-publication ordering, and combined failures.
