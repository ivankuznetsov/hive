---
date: 2026-09-25
title: Harden one-shot ownership and stop-safety
tags: [daemon, one-shot, ownership, liveness]
---

- Contained per-project configuration failures during daemon guard refresh,
  retained disabled or removed projects until their work drains, and added a
  PID-generation plus enabled-enrollment fence for daemons started before the
  project guard existed.
- Moved guard owner diagnostics to an atomically replaced sidecar, removed it
  before unlock, and retained verified typed routine-refusal details during
  contention.
- Added one project-wide stop-safety probe covering durable attempts and live
  task-lease runner/agent processes, including dry-run, and wired Patrol,
  Architecture Patrol, and babysitter reports to it.
- Pinned one-shot Hive child commands to `HIVE_BIN`, completed the runtime
  control-plane consumer inventory, and added controlled process-lifecycle
  proof for the runner.
