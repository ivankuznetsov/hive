---
title: Merge external-scheduler one-shot runs with daemon quiescence
type: log
created: 2026-09-27
tags: [daemon, quiescence, one-shot, babysitter, runtime-control-plane]
---

- Merged main's one-shot scheduler entry points (#1477) into the daemon
  quiescence branch (#1483). `hive daemon` accepts both `quiesce`/`resume` and
  `clear-hold`, plus `--once`; `--once` rejects `--timeout`.
- `Hive::OneShot::Runner.build` wires the durable lifecycle
  `persistent_admission` probe into its scoped dispatcher, and the default
  `hive babysit --once` adapter passes the same probe into `ProjectTick`.
- One-shot patrol children now spawn through
  `CommandRegistration.spawn_registered_hive!` so quiescence sees them.
- `Attempts::Reconciler#reconcile` accepts `authority:`/`timeout_sec:` and
  `mutate_projects:` together; interrupted hook attempts are retryable through
  the shared `DaemonRuntime#retryable_attempt?` helper (readiness and reconcile
  agree).
