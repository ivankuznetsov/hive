## [2026-08-24T12:04:10Z] status — add bounded live-task projection

**Action:** Added `hive status --running --json` and the versioned
`hive-running-status.v1` schema for authenticated widgets and polling clients.
The producer reads only bounded task locks and live-row metadata, verifies
runner and child process identity, emits explicit liveness, and never builds
the complete status graph. It caps project and directory-entry traversal,
opens task and daemon PID files nonblocking, and rejects missing process
identity in this compact contract. Output is capped at 32 rows and 64 KiB with
explicit exact/inexact omission metadata; `hive status --json` remains
unchanged at v7.

**Verification:** Added focused coverage for empty output, lock-only liveness,
live orphaned agent PIDs, stale and malformed locks, task transitions,
malformed/FIFO metadata, reused and oversized PIDs, daemon PID bounds,
project/filesystem scan caps, row/string/output caps, CLI mode isolation, and
schema validation.

**Refreshed pages:**
- [[commands/status]]
- [[modules/lock]]
- [[testing]]
