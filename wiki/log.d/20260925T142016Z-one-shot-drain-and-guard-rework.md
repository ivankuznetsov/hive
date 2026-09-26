---
date: 2026-09-25
title: Close one-shot drain and replacement ownership gaps
tags: [daemon, one-shot, scheduling, ownership]
---

- Bounded dispatch one-shot liveness draining with a monotonic deadline. An
  orphaned Architecture Patrol discovery claim or unreadable job store now
  yields a typed unsafe `drain_timeout` report while retaining completed-work
  evidence.
- Keyed daemon project guards by canonical state-root identity. Re-registering
  a project name cannot reuse the old root's lock to authorize the replacement;
  aliases share a lock, and retired roots remain guarded until drained.
