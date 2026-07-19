---
title: Share the PID liveness probe
type: changed
date: 2026-07-18
---

Claude-session completion, migration guards, status, dispatcher recovery,
display-name backfill, and stale-agent healing now delegate their PID-only
liveness checks to `Hive::ProcessKill.pid_alive?`. Their private method seams,
`ESRCH`-means-dead behavior, and conservative `EPERM`-means-alive behavior are
unchanged.
