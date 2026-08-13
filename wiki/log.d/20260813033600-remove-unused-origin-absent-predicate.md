---
title: Remove unused origin-absence predicate
date: 2026-08-13
---

- Removed the uncalled `Hive::RepositoryIdentity.origin_absent?` predicate,
  which was left behind when digest registration stopped distinguishing a
  missing `origin` remote from other lookup failures.
- Repository identity consumers continue through the bounded
  `RepositoryIdentity.current` lookup; its missing-origin, spawn-failure, and
  timeout behavior remains covered.
