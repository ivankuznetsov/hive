---
title: Remove unused publication pre-create predicate
date: 2026-08-13
---

- Removed the uncalled
  `Hive::RefactorPatrol::PublicationAttempt.pre_create?` predicate. Publication
  recovery continues to use the retained attempt state, phase evidence, and
  receipt predicates.
