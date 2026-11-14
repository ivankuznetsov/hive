---
title: Daemon status payload leaves the runtime write lock; runtime writes are labelled
type: change
created: 2026-11-14
updated: 2026-11-14
tags: [daemon, runtime-database, sqlite, write-lock, operational-status, observability]
---

The dogfood daemon (origin/main 69511db1b) logged 16 `operational.publish`
holds over 1 s in 6 h (p50 3.2 s, max 9.4 s) and 43 unlabelled
`runtime.write` holds (one 15 s), all from the daemon PID. CLI writers such as
`hive act workflow.retry` exhausted their busy budget and exited 75. The
`daemon_runtime` row was 5.3 MB, 5.1 MB of it the `hive-status` projection
(~4 MB `plan_review`). Encoding already ran before `BEGIN IMMEDIATE`, but
SQLite rewrites a whole row on update, so every tick still fsynced megabytes
of WAL under the lock on a host with 14 GB swap and I/O PSI avg60 32 %.

- `OperationalRepository#publish` stores the projection envelope (daemon,
  tick, deadlines) in the row with a `payload_reference` (SHA-256, byte size,
  per-tick `generated_at`, positional task `age_seconds`). The payload body is
  a content-addressed file in `operational-status-payloads/` beside the
  database (`Hive::Paths.operational_status_payload_root`), written by the new
  `RuntimeControlPlane::OperationalPayloadStore` before the lock, without
  fsync, and only when its digest changes. The row drops to ~220 KB.
- `status_projection` keeps the same contract: the envelope's tick and daemon
  must match the snapshot in the same row, then the file must match the
  reference's size and digest; any mismatch, missing file, or bad age entry
  raises `IntegrityError` and status falls back to a fresh scan. Rows with an
  inline payload still read. An unwritable payload directory publishes the
  scheduler record without a projection and logs
  `operational_projection_unavailable`. Files are pruned to the current and
  two previous digests.
- Measured on tmpfs with two captured live projections: row 5.33 MB → 222 KB;
  lock hold p50 59 ms → 1.3 ms (excludes fsync); an idle tick wrote no file.
- Unlabelled runtime writes now name their operation: dispatch requests,
  task leases, process reconciliation, lifecycle transitions, attempt
  coordination/lost-outcome/log-archive, usage, task counter, project
  identity, registry sync, quiescence, command-schema install, and command
  receipts. `RuntimeTransactionLabelsTest` guards those files; test doubles
  for `transaction` now accept keywords.
- Pages: [[modules/daemon]], [[commands/status]], [[gaps]].
