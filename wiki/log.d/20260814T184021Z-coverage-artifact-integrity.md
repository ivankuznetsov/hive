---
title: Make sharded coverage artifact transport collision-safe
slug: coverage-artifact-integrity
date: 2026-08-14T18:40:21Z
---

**Action:** Stopped flattening coverage artifacts after hosted-run accounting
proved that identical PID/object-ID result basenames silently overwrote four
collector results. Each shard now publishes an identity-bearing
`hive-coverage-shard.v1` manifest. The aggregate retains per-shard directories,
requires the exact revision, workflow run, Ruby version, shard set, test-file
partition, and nonempty result inventory, rejects foreign or unlisted files,
then merges only verified paths. Collector retries overwrite the prior
same-name artifact, startup require failures persist as error markers, empty
shards fail before execution, and the named coverage aggregate reports failed,
skipped, or cancelled collectors directly.

**Verification:** Focused coverage and workflow-contract suites pass with 25
tests and 236 assertions; the coverage-instrumented Workflow Creator gateway
and supervisor suites pass with 21 tests and 152 assertions; RuboCop is clean.
A deliberate nonzero-shard probe
with full-catalog preload failed four clean-load gateway tests, so that
experiment was rejected and the shard-zero-only preload contract remains.
Two exhaustive local coverage attempts then exposed one-second subprocess
deadlines in the gateway and lower-level supervisor success fixtures under
coverage-instrumented `exit!` flushing. Their ordinary success-path deadlines
are now five seconds; explicit timeout/escalation cases keep their subsecond
values, and production retains its 120-second default. Exact-head hosted
transport and timing proof is still pending.
