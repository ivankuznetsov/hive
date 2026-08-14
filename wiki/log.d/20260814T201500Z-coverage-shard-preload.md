---
title: Preserve monolithic source loading in every coverage shard
slug: coverage-shard-preload
date: 2026-08-14T20:15:00Z
---

**Action:** Enabled the complete source-catalog preload in every hosted coverage
partition. A current-main control passed exact coverage at 87,235/87,235 lines,
while the shard-zero-only preload collected all six manifests and 1,627 process
results but covered only 83,296/87,235 lines. The partitioned suite therefore
must preserve the monolithic source-loading contract in each test process.

**Verification:** Replayed the 185-file nonzero partition that had rejected the
first full-preload experiment after raising its coverage-instrumented subprocess
fixture deadlines. It passed 3,395 tests and 17,762 assertions in 321 seconds,
including the Workflow Creator gateway paths that previously timed out. Hosted
six-shard exact coverage remains the final proof.
