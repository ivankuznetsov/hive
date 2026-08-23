---
title: Status scans reuse one durable attempt store
date: 2026-08-22
---

- `hive status` now opens one read-only durable attempt store per full scan and
  shares it across task-journal and closure projection for every row.
- The scan-scoped projection reader caches each immutable binding or missing
  result once; on the live fleet this reduced global point reads from 10,120
  to 6,723 and reduced one status scan from about 23 seconds to about 18.
- Large task corpora no longer repeat attempt-store initialization for each
  task during a status scan.
- The projection payload is unchanged; a regression test pins scan-scoped
  reuse across multiple tasks.
- Attempt stores, daemon startup, and bot startup no longer invoke the global
  recovery migration or monitor legacy state. Only `hive migrate` and
  `hive migrate --all` perform the quiesced cutover.
