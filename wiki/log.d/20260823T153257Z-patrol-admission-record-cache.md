---
title: Patrol admission reuses unchanged validated records
type: change
tags: [daemon, patrol-fix, performance, admission]
---

The daemon now retains one Patrol Fix admission store per active project.
Runtime pending scans reread only the index-selected due records and reuse each
frozen validated projection when its SHA-256 digest is unchanged. Full
inventory consumers also reuse unchanged projections while retaining their
single-session reads. External writes invalidate the cache and receive the full
schema, source, candidate, and state validation before use; removed project
stores are evicted. A store retains no more than 512 records or 16 MiB of their
serialized bytes, keeps a stable subset during oversized scans, and immediately
removes entries deleted by capacity compaction.
