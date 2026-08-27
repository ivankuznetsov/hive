---
title: Keep parked Patrol outcomes out of operator decisions
type: change
date: 2026-08-25
---

`hive status --operational` no longer classifies rejected, blocked, or
escalated Patrol Fix outcomes as `waiting_on_you`. The hidden v7 compatibility
graph still publishes their non-runnable `needs_input` action, while the
operational projection recognizes the terminal parked shape and reports
`completion_ready` with no blocker owner. Ordinary editable `needs_input` rows
remain operator-owned.
