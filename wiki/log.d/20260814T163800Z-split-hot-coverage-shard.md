---
title: Split the measured hot coverage shard
slug: split-hot-coverage-shard
date: 2026-08-14T16:38:00Z
---

**Action:** Added one coverage collector by splitting only the third member of
the original four-way source-byte partition. The other three partitions remain
stable, shard zero still owns the Agent CLI Runtime suite and full source load,
and the downstream exact 100% merge plus protected aggregate are unchanged.

**Measurement:** The third collector was the slowest in both exact-head hosted
runs: 410 seconds in run `31818138021` and 440 seconds in run `31819264376`.
The second run's other collectors took 244, 270, and 294 seconds. Splitting the
repeatedly measured long pole adds one job instead of doubling the whole
matrix. Exact-head hosted timing is required before accepting the result.
The two new halves passed locally in 174 and 209 seconds under collection mode;
an earlier 451-second sample of the second half was discarded as contended
after the exact same file set reran cleanly and the per-file profile accounted
for the stable 209-second duration.
