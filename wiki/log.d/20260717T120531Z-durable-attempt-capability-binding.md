---
title: Authenticate durable attempt launch and worker context
date: 2026-07-17
tags: [attempts, security, ownership, supervisor]
---

- Persist the exact admitted worker argv and only a SHA-256 digest of a random
  per-attempt launch capability in the immutable attempt record.
- Pass claim authority through an inherited descriptor, remove arbitrary worker
  argv from `__attempt-supervise`, and make the supervisor execute the record.
- Gate Hive worker startup until its PID/start/session/group identity is
  durably checkpointed, then authenticate argv, task, intended stage, state,
  identity, and capability before installing process-local attempt context.
- Scrub inherited `HIVE_ATTEMPT_*` transport keys before any worker descendants
  can inherit the durable-admission bypass.
