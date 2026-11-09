## 2026-11-08 — Durable attempt scopes get a configurable memory cap

- New global daemon keys `daemon.attempt_memory_max` (default `"6G"`) and
  `daemon.attempt_memory_swap_max` (default `"0"`). They accept `false`
  (disabled), a byte Integer, or a systemd size such as `"512M"`, `"6G"`,
  `"50%"`, or `"infinity"`, and are validated by `validate_daemon!`.
- `Attempts::DetachedLauncher` adds `MemoryMax`, `MemorySwapMax`, and (on
  systemd >= 253) `OOMPolicy=continue` to the `hive-attempt-*.scope`
  `systemd-run` argv. With the default `OOMPolicy=stop`, one OOM kill would
  stop the whole scope, including the supervisor. The cap is a no-op when no
  systemd user scope is used (macOS, no user bus, plain spawn).
- New `Hive::Attempts::MemoryLimit` holds the size validation, the scope
  properties, the systemd version probe, and the cgroup v2 `oom_kill` reader.
- `Attempts::Supervisor` compares the scope's `memory.events` `oom_kill`
  counter before and after the worker runs. If the worker died by SIGKILL
  while the counter rose, it logs
  `failure_reason=memory_limit_exceeded` and sets the patrol diagnostic's
  `agent_reason`. A kill of a descendant only logs a notice.
- Motivation: an uncapped Codex reviewer probe grew to 4.6 GB in seconds on
  the 16 GB dogfood host. Remaining gaps (receipt field, review CI cap,
  memory admission) are listed in `wiki/gaps.md`.
