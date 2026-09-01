---
title: Cut attempts and routing policy over to the runtime control plane
date: 2026-08-29
tags: [sqlite, attempts, admission, payloads, routing]
---

- Replaced filesystem attempt records, proof/index sidecars, pending
  finalization cells, capacity/accounting locks, failure cohorts, and routing
  policy point storage with Sequel dataset repositories and immediate SQLite
  transitions.
- Preserved `Hive::Attempts::API` and validated `Record` values while making
  source/request/generation binding, lifecycle CAS, capacity reservation,
  terminal/lost release, and publication acknowledgement transactional.
- Routed terminal logs and outputs through `PayloadStore#seal`, persisted their
  canonical content addresses, and replaced cold-directory scans with bounded
  SQL keyset retention.
- Kept migration explicit: normal CLI, Web, status, bot, and daemon paths open
  only the activated state-home database and ignore the legacy attempt-root
  override outside import.
