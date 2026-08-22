---
title: Status scans reuse one durable attempt store
date: 2026-08-22
---

- `hive status` now opens one read-only durable attempt store per full scan and
  shares it across task-journal and closure projection for every row.
- Large task corpora no longer repeat attempt-store initialization for each
  task during a status scan.
- The projection payload is unchanged; a regression test pins scan-scoped
  reuse across multiple tasks.
- Attempt stores, daemon startup, and bot startup no longer invoke the global
  recovery migration or monitor legacy state. Only `hive migrate` and
  `hive migrate --all` perform the quiesced cutover.
