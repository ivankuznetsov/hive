---
title: Multi-dependency review fix pass 01
date: 2026-10-15
---

- Bounded cycle-derived admission walks with a root-local memo while preserving
  root-relative cycle paths.
- Kept tolerant status declarations schema-valid while strict admission retains
  malformed evidence, and preserved scalar command receipt fingerprints.
- Reused project policy and batched branch evidence across status rows; lazy
  incremental base selection now fails soft without blocking independent tasks.
- Included declaration shape in admission fingerprints and retained scalar
  diagnostic contracts for multi-blocker waits.
- Extended regression coverage for declaration shape, singleton projections,
  root order, duplicate notices, deferred creation errors, freshness, and
  consumer error precedence.
