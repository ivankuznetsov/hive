---
title: Architecture Patrol tolerates its own atomic job temporaries
type: fix
created: 2026-08-15
tags: [refactor-patrol, jobstore, atomic-write, recovery]
---

`JobStoreFiles` now distinguishes ManagedDirectory's exact writer-owned job
temporary names from unknown inventory entries. A regular temporary, or one
that vanishes while its rename completes, is ignored by authoritative job
enumeration; a non-regular temporary and every other unknown name still fail
closed. ManagedDirectory owns the shared temporary-name classifier, and the
bounded inventory reserves one temporary slot per admitted job. This prevents
concurrent v4 job publication from surfacing as
`repository_identity_unresolved`, including at capacity, and blocking
unrelated Architecture Patrol jobs. Non-directory descriptor probes are also
nonblocking, so a temp-shaped FIFO fails closed instead of hanging inventory.
Each job-lock holder removes exact temporaries left by the previous writer,
bounding crash residue to one temporary per admitted job.
