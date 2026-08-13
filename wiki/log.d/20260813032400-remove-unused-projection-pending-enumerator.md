---
title: Remove unused Patrol projection-pending enumerator
date: 2026-08-13
---

- Removed the uncalled
  `Hive::Patrol::StateStore#each_projection_pending_occurrence` forwarding
  method.
- The reserved-occurrence, general-occurrence, and projection-predicate
  cleanups are explicit dependencies. Together the removals orphaned the
  journal's reserved and projection-pending views, so those views were removed
  while the live bounded recovery view remains.
