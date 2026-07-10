## 2026-07-10 — Reload daemon concurrency limits in place

**Action:** `hive daemon reload` now applies the reloaded global, per-project,
daily, and patrol-scan concurrency limits to the existing
`ConcurrencyController`. Updating the controller in place preserves live child
accounting, cooldowns, quarantine, daily counters, and dispatch baselines while
subsequent admission decisions use the new limits immediately. Explicit YAML
`null` values for numeric daemon settings are rejected during config validation,
so an invalid reload cannot replace a live controller limit with `nil`. The
structured `config_reloaded` event now includes the four effective limits so
automation can verify the applied result rather than only the delivered signal.

**Root cause:** `Dispatcher#reload_config!` reloaded the global daemon YAML into
`@daemon_cfg` but refreshed only selected consumers such as child timeouts and
healers. The controller retained the limits captured by its constructor until
a full daemon restart.

**Tests:** Added a focused SIGHUP regression that changes every controller-owned
limit, asserts the controller object and in-flight state are retained, and
proves the new per-project cap affects the next dispatch check. Added config
coverage for null concurrency limits.

**Wiki pages updated:** `wiki/commands/daemon.md`, `wiki/modules/daemon.md`, and
`wiki/gaps.md`.
