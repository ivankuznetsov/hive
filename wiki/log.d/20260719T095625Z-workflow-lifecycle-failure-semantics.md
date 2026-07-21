---
title: Workflow lifecycle failure semantics and real web adapter coverage
type: change
date: 2026-07-19
tags: [workflows, web, concurrency, testing, errors]
---

- Workflow preview registries now reject incomplete candidate identities, and
  update receipts require the original commit and manifest digest explicitly.
- A local immutable registry fixture drives preview/apply install, update, and
  remove through the real Hive Web adapter and real command constructors.
- Failed activation cleanup preserves the original error. Failures after a
  committed update/removal return success plus operator-visible warnings.
- Mutation-lock yield errors keep their real classification, registry git
  errors retain bounded stderr, and the managed-store CAS sentinel is private
  and documented.
- Added receipt replay, expiry, and per-operation consent negatives plus
  command failure-path regressions.
