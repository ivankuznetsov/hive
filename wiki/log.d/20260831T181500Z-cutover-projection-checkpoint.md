---
title: Advance retained task checkpoints after the SQLite cutover
tags: [runtime-control-plane, cutover, task-journal, projection, attempts]
---

The all-in SQLite cutover intentionally resets legacy attempt rows while
preserving task journals and validated projection checkpoints. A post-cutover
activity append previously tried to rebuild the complete journal and rejected
its historical attempt IDs as unknown.

Checkpoint advancement now uses the installation's durable activation timestamp
as the boundary. A prefix that still passes its cursor, inode, and anchor checks
may classify a missing pre-activation binding as lost before validating the
suffix against SQLite. Strict full replay and missing post-activation attempts
still fail closed; the journal remains immutable and SQLite receives no
synthetic legacy row.
