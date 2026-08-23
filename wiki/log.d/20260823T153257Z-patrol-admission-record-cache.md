---
title: Patrol admission reuses unchanged validated records
type: change
tags: [daemon, patrol-fix, performance, admission]
---

The daemon now retains one Patrol Fix admission store per active project.
Admission scans still reread each bounded durable record, but reuse its frozen
validated projection when the SHA-256 digest is unchanged. External writes
invalidate the cache and receive the full schema, source, candidate, and state
validation before use; removed project stores are evicted. A store retains no
more than 512 records or 16 MiB of their serialized bytes, keeps a stable subset
during oversized scans, and immediately removes entries deleted by capacity
compaction.
