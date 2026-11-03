# 2026-11-03 — Honor a project's own daemon.max_concurrent_per_project

- The daemon now reads `daemon.max_concurrent_per_project` from each
  project's `.hive-state/config.yml` (per tick, cached with
  `daemon.enabled`) and uses it to lower that project's task cap. It never
  raises the daemon-wide per-project cap; non-positive or non-integer values
  are ignored.
- Before this, the project-level key was silently ignored even though
  project configs (including Hive's own) set it expecting it to apply.
- Code: `Hive::Daemon::ConcurrencyController#project_limit` /
  `#project_cap=`, `Hive::Daemon::Dispatcher#project_concurrency_cap`.
