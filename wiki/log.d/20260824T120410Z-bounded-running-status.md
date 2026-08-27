## [2026-08-24T12:04:10Z] status — add bounded live-task projection

**Action:** Made bare `hive status` and `hive status --json` the versioned,
bounded `hive-running-status.v1` surface for humans, authenticated widgets,
and polling clients. Removed the former public `--full`/v7 graph mode;
operators use `--operational`, `hive task`, `hive tui`, or `hive archive`
according to the question they are answering. The daemon and bot's remaining
v7 dependency is explicitly hidden as an internal transport pending separate
consumer-projection PRs.
The producer reads only bounded task locks and live-row metadata, verifies
runner and child process identity, emits explicit liveness, and never builds
the complete status graph. It caps project and directory-entry traversal,
opens task and daemon PID files nonblocking, and rejects missing process
identity in this compact contract. Output is capped at 32 rows and 64 KiB with
explicit exact/inexact omission metadata.
Release and channel verification now exercise the public compact and
operational contracts. Upgrade-survivor snapshots no longer capture a
duplicative full status graph because they already preserve durable task state.

**Verification:** Added focused coverage for empty output, lock-only liveness,
live orphaned agent PIDs, stale and malformed locks, task transitions,
malformed/FIFO metadata, reused and oversized PIDs, daemon PID bounds,
deeply nested YAML, project/filesystem scan caps, row/string/output caps, CLI
mode isolation, release-consumer routing, and schema validation.

**Refreshed pages:**
- [[commands/status]]
- [[modules/lock]]
- [[testing]]
