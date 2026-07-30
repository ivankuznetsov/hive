---
title: Bound install-wide migration evidence and reconcile conversion occurrences
type: change
date: 2026-07-30
tags: [patrol, migration, recovery, all-users]
---

- Kept full registered-project results in each dropped-identity user's
  authoritative receipt while replacing the root traversal checkpoint and
  aggregate with fixed digest/count summaries.
- Raised the canonical child receipt wire to the existing 2 MiB store contract
  with an independent bounded stderr stream, preventing large valid profiles
  from being killed or starving users later in the host sweep.
- Made v3 conversion resume reconstruct and verify the deterministic occurrence
  and intake intent before completion. Completed imports require an exact live
  finalized/all-acknowledged record or its retirement fence; incomplete jobs
  retain their reserved continuation occurrence.
- Replaced the unreleased draft checkpoint shape directly. No runtime legacy
  reader or compatibility branch was added.
