---
title: Retire stale recovery dispatch requests
tags: [daemon, dispatch, recovery, queue, archive]
---

Recovery requests previously remained queued when their task advanced to a
different stage or disappeared from the active graph after archive. The daemon
reported those superseded rows as pending indefinitely and retried their
recovery observation even though the bound task identity could no longer be
current.

Dispatch now rejects a recovery request as `stale_task_identity` before
coordinator resume when its task ID/stage no longer matches, or when its row is
absent from a project whose status graph was successfully observed. A
project-level status failure or a legacy-layout scan is not proof of archive,
so Hive preserves that request as `recovery_observation_unavailable`. A healthy
canonical scan confirms the exact task identity before removing an absent row.
The same exact resolution protects against a task advancing after the status
snapshot but before queue processing. Current operator-owned
deterministic-failure receipts remain durable and are not mistaken for stale
work. Requests already parked as `generation_conflict` or
`task_identity_conflict` are also retired: the coordinator classified their
bound transition as immutable, so preserving them only creates an inert queue
row and cannot make the task runnable again.
