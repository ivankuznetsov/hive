---
title: Bound Patrol admission inventory traversal
type: change
date: 2026-08-22
tags: [daemon, patrol-fix, admission, performance, managed-directory]
---

`AdmissionStore#each_record` now uses one non-creating `ManagedDirectory` read
session. It fully enumerates the inventory and rejects unknown entries or
`MAX_RECORDS` overflow before reading any record. After occurrence IDs are
validated and sorted, `ManagedDirectory#read_children` streams the
caller-validated names through one opened parent directory. Canonical record
parsing, full record validation, and descriptor/name-binding validation still
run per record. The optimization makes root opening and directory traversal
constant as the record count rises; bounded record reads and validation remain
linear. Reads remain lock-free and do not create an absent store.

This is only a storage-local scan optimization. It adds no migration, daemon
watcher, cache, schema, scheduler-policy, capacity, or task-materialization
behavior.

The measured dogfood workload had four registered projects and 221 tasks. The
Hive project's admission store contained 54 JSON records. On exact
`origin/main`, one daemon tick used 10.917531574 seconds of process CPU; the
repeated `AdmissionStore#fetch` to `ManagedDirectory#open_root!` stack accounted
for 3.53678 seconds. The optimized daemon tick no longer contained the repeated
`each_record`/`fetch`/root-open stack. Whole-tick CPU was noisy and did not
establish a total-tick reduction, so no total-tick improvement is claimed.

Two isolated same-store comparisons ran three full pending scans per head:

- Comparison 1: `origin/main` used 14.312698077 CPU seconds and the branch used
  13.385584423 seconds.
- Comparison 2: `origin/main` used 11.590105895 CPU seconds and the branch used
  11.470292061 seconds.
- Aggregate: `origin/main` used 25.902803972 CPU seconds and the branch used
  24.855876484 seconds, about 4.0% lower.

After review replaced the read-side inventory lock with the final non-creating
read session, another three-scan branch run over the same 54 records used
11.011560469 CPU seconds. This is a consistency check, not a new comparative
claim.

Direct regression tests prove one absolute root open per pending inventory scan
and constant directory traversal as the record count rises. Separate assertions
retain the requirement that unknown entries and inventory overflow fail before
record reads.
