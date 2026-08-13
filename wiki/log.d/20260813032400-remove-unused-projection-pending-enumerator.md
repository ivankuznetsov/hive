---
title: Remove unused Patrol projection-pending enumerator
date: 2026-08-13
---

- Removed the uncalled
  `Hive::Patrol::StateStore#each_projection_pending_occurrence` forwarding
  method. The migration occurrence journal retains its canonical
  projection-pending query and focused coverage.
