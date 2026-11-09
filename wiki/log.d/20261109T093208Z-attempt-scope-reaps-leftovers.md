## 2026-11-09 — Attempt supervisors reap their scope's leftover processes

- New `Hive::Attempts::ScopeReaper`. Once the worker is gone, the supervisor
  sends SIGTERM to every other process still in its own
  `hive-attempt-<digest>.scope` cgroup, including descendant cgroups. After
  the kill grace it sends SIGKILL and waits up to 2 s. It acts only when the
  supervisor's cgroup is exactly the unit derived from its own attempt id,
  and it re-checks each pid's cgroup right before signalling it.
- This runs on every supervisor exit path, before the attempt log is closed
  and the terminal receipt is written. Anything it reaped is logged as
  `hive-attempt: scope_leftovers {…}` with pid and `comm`, plus survivors and
  status. A clean scope logs nothing.
- `DetachedLauncher` now names the scope through `ScopeReaper.unit_name`, so
  the launcher and the reaper share one derivation.
- Motivation: a review agent's `podman run` left `conmon` and `pasta` in a
  terminal attempt's scope, which kept the scope active for about 7.5 hours
  and blocked hivedev spike windows. Hive's own drain paths count attempt
  records and pid identities, not scopes, so their output is unchanged. The
  remaining gaps are listed in `wiki/gaps.md`.
