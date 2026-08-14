---
title: Keep sharded collectors lazy for durable fork coverage
slug: coverage-sparse-fork-collection
date: 2026-08-14T20:40:00Z
---

**Action:** Disabled complete source-catalog preload in every hosted collector.
The final report independently enumerates all `lib/` sources and fails absent
or uncovered files, while lazy parents let forked custody children flush small
coverage payloads inside their bounded test deadlines.

**Evidence:** On current main, monolithic coverage captured 1,678 results and
passed 87,235/87,235 lines. Shard-zero-only preload captured 1,627 results and
83,296/87,235 lines. Full preload on all six collectors reduced the durable
inventory to 1,374 results and 79,103/87,238 lines even though every collector
test passed. The inverse relationship between inherited catalog size, durable
child results, and coverage isolates collector preload as the loss mechanism.
A first exact-head lazy-collector run exposed a test-only environment leak: the
new prepare-task contract test restored its input metadata but not the six
coverage variables mutated by the Rake task, so a later subprocess inherited
the nonempty-test guard and failed. The fixture now restores the complete
environment mutation surface. Exact-head lazy-collector proof is pending.
