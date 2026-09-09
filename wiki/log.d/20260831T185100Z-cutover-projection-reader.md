---
title: Carry the cutover boundary through routine projection reads
tags: [runtime-control-plane, cutover, task-projection, status]
---

Routine status scans use the attempt repository's bounded projection reader,
not the full repository facade. That reader now delegates the durable
pre-activation boundary check, so daemon and Web snapshots advance retained
cutover checkpoints under the same rules as direct task projection reads.
