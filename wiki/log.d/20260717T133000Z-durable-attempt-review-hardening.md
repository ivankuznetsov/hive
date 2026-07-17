---
date: 2026-07-17
summary: Close durable-attempt review gaps across launch, recovery, and daemon restart
---

- Failed or false launcher handoffs now mark unclaimed reservations lost and
  defer retryably; a wrapper that already claimed is adopted after a CAS race.
- Lost foreground attachments raise a typed retryable error so both run and
  workflow JSON surfaces emit versioned envelopes.
- Loss successors preserve exact admitted workflow argv/flags, retarget moved
  task folders, and remove only a source assertion already satisfied on disk.
- Queue claims repair a crash-window missing attempt ID from immutable request
  correlation, and daemon admissions resolve attempt timers per project.
- Removed production context construction/thread overrides and ignored
  worker-supplied store paths; documented the remaining same-UID privilege
  boundary explicitly.
- Preserved attempt process groups across systemd daemon replacement and made
  a surviving leaderless group fail closed during orphan reconciliation.
