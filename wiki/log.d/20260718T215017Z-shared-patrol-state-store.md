---
title: Share legacy patrol state persistence
created: 2026-07-18T21:50:17Z
tags: [patrol, refactor-patrol, refactor, state]
---

- Extracted the identical ordinary-patrol and architecture-patrol legacy JSON
  lifecycle into `Hive::Patrol::BaseStateStore`.
- Kept both public state-store classes, on-disk namespaces, domain records,
  tolerant-read behavior, and prior no-fsync write semantics unchanged.
- Routed atomic replacement through the existing `Hive::AtomicFile` primitive,
  removing duplicate temporary-file and rename implementations.
