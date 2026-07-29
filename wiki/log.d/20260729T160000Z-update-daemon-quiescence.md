---
title: Fence installed updates around the daemon writer
date: 2026-07-29
pages: [commands/update, update-flow]
---

`hive update` now preflights the selected package helper before changing daemon
state. When a verified daemon is running, it captures the daemon's supervised
writer tree, runs the existing stop lifecycle, and waits for a
generation-bound dispatcher acknowledgement written after admission closure
and ChildSupervisor drain. Repeated post-TERM tree snapshots add late children
and process groups to the final inventory. Package activation is refused until
the old PID and every observed child/group are absent. A successful update
starts only a daemon it stopped, through the post-update stable wrapper; a
failed activation also attempts that restart so the active installation is not
left needlessly unavailable. The JobStore conversion retains its separate
writer fence for manual candidate invocation.
