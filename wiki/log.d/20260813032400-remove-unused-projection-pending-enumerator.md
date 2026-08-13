---
title: Remove unused Patrol projection-pending enumerator
date: 2026-08-13
---

- Removed the uncalled
  `Hive::Patrol::StateStore#each_projection_pending_occurrence` forwarding
  method.
- The reserved-occurrence cleanup is now an explicit dependency. Together the
  two removals orphaned the journal's reserved and projection-pending views,
  so those views were removed while the live bounded recovery view remains.
