# 2026-10-03 — Operational status audits read-only state

- `hive status --operational --json` now tries ordinary writable startup and
  registration first, then enters invocation-scoped inspection only after a
  typed read-only failure on a Linux mount confirmed by unambiguous procfs
  metadata. Other commands and in-process callers retain writable registration.
- Clean databases use immutable inspection, readable WAL/SHM pairs use plain
  read-only inspection, and unpaired or inaccessible sidecars return typed
  storage guidance without checkpointing, removal, mutation, or backup advice.
  Corruption and custody violations retain their established handling.
- A required Docker gate proves runtime and operational status on real
  read-only mounts for clean and retained-WAL fixtures across valid, absent,
  and expired cache variants. It also proves both unpaired-sidecar refusals and
  retains candidate, mount, command, and unchanged-state evidence in CI.
