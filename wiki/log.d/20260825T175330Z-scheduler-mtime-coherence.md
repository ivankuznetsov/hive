---
title: Keep controller scheduler observations coherent with status
type: fix
date: 2026-08-25
---

Daemon task rows now retain the exact task-graph payload `mtime` separately
from the precise local state-file timestamp used by edit-resume and recovery.
Operational scheduler snapshots use the payload timestamp for their same-tick
identity join, so Patrol Fix controller rows whose folder and manifest mtimes
differ no longer produce fleet-wide `scheduler_task_mismatch` issues. During
cutover, a same-tick cached legacy Patrol controller treats only its unavailable
payload timestamp as unknown; fresh scans retain the mismatch guard.
