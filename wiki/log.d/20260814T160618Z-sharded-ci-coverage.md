---
title: Split exhaustive CI coverage into four collectors
slug: sharded-ci-coverage
date: 2026-08-14T16:06:18Z
---

**Action:** Replaced the monolithic hosted coverage execution with four
deterministic, source-byte-balanced collection jobs and one downstream exact
merge. Each default test file belongs to exactly one shard. Shard zero also
runs the Agent CLI Runtime component suite and owns the full source-catalog
load; the remaining collectors avoid repeating that fixed cost. Raw stdlib
Coverage process results are uploaded separately, downloaded into one result
set, and accepted only when the unchanged exact 100% gate passes. The existing
protected `rake test (Ruby 3.4)` aggregator and all outer proof gates remain
fail-closed.

**Measurement:** The four most recent successful `main` CI runs had a 1,592
second median workflow duration. Their coverage job median was 1,581 seconds,
including 1,561 seconds in the minitest/coverage step; the next-longest job was
Hive web at 409 seconds. Three local collectors passed in 187, 356, and 486
seconds. The fourth completed in 560 seconds with one host-contention timeout
that passed immediately in isolation. Their 1,546 raw process results merged
successfully to
84,609/84,609 covered executable lines, with zero unloaded files and zero
result errors. Exact-head hosted timing remains the authoritative before/after
proof and is recorded as an open gap until the pull request runs.
