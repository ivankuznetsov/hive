---
title: Clarify operational liveness evidence and review diagnostics
date: 2026-11-01
tags: [operational-status, liveness, status, review]
---

- The generic running reason now says "task is running", including rows whose
  running state comes only from the action without a live PID.
- Status documentation distinguishes agent PID-existence checks from lock
  checks that also match process start time when recorded, states the running
  action/marker precondition for stale repair, and names the current v5 error
  schema. Corrected the earlier liveness change fragment's matching claims.
- Looped liveness assertions include their case labels, including schema
  validation and neighboring scheduler/ownership assertions.
