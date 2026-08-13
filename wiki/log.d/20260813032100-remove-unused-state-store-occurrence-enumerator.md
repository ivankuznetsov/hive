---
title: Remove unused Patrol occurrence enumerator
date: 2026-08-13
---

- Removed the uncalled `Hive::Patrol::StateStore#each_occurrence` forwarding
  method. Patrol's runtime continues to use the state store's purpose-specific
  reservation and recovery queries, while the migration occurrence journal
  retains its canonical record traversal.
