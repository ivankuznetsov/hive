---
title: Remove unused finding semantic wrapper
date: 2026-08-13
---

- Removed the uncalled `Hive::Patrol::Fingerprint.semantically_same?`
  convenience wrapper. The live finding registry continues to precompute
  signatures and compare them with `semantically_same_signature?`.
- Retargeted the fuzzy-match and category-boundary assertions to that live
  signature API.
