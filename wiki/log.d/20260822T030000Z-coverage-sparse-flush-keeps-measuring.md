# Coverage: a sparse `exit!` flush no longer stops measurement

**Date:** 2026-08-22
**Scope:** `test/support/coverage.rb`, `test/unit/coverage_test.rb`, `wiki/testing.md`

## What changed

`HiveTestCoverage.dump_process_result!` now reads
`Coverage.result(stop: false, clear: false)` instead of the bare
`Coverage.result`, and no longer latches `@dumped` on a successful dump.

## Why

`Coverage.result` ends measurement by default. The pre-`exit!` sparse flush
installed by `test/hive_coverage_boot.rb` can run in a process that keeps
executing tests afterwards — a fork parent, or a stubbed `exit!` that never
reaches `Kernel#exit!`. When that happened, collection stopped mid-suite, every
line the process ran later went unmeasured, and the `@dumped` latch plus the
"coverage measurement is not enabled" rescue silently discarded the final dump.
The shard still exited zero, so CI reported green per shard while the merged
gate fell far short.

Observed on PR #1167 CI run 32543481455: merged coverage read 91.40%
(88935/97302) with all six shards green. 6946 of the 8367 uncovered lines
belonged to test files owned by shard index 1. For
`lib/hive/tui/bubble_model.rb`, shard 1's best surviving dump covered 460 of
1214 executable lines and the union across shards reached 514 — exactly the 700
the gate reported uncovered — while running `test/unit/tui/bubble_model_test.rb`
alone locally covers 1178. Because the deficit follows whichever shard trips the
early flush first, it migrated between shards on every repartition, which made
it look like partition-induced flake rather than a harness bug.

## Coverage

`test_sparse_flush_keeps_measuring_lines_executed_afterwards` in
`test/unit/coverage_test.rb` drives a real subprocess through
sparse-flush-then-execute-more and asserts the later code is still measured. It
fails on the previous implementation.
