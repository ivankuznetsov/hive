---
title: Bound Architecture Patrol recovery reads
type: fix
date: 2026-08-07
---

Architecture Patrol recovery now reads and validates one occurrence snapshot
per job. Recorded transitions whose effect cells are already terminal are
checked against that snapshot instead of fetching and validating the same
occurrence once per transition. Nonterminal transitions retain the existing
fresh intent/state read before replay, preserving concurrent recovery safety.
