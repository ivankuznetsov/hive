# 2026-11-06 — daemon: settle stranded attempts in dispatch-disabled projects

**Action:** Fixed a quiescence dead end on hivedev. Attempt
`d0ce57a6-3951-4162-ac66-fe09354f0067` (project topgreendeals, task 43422)
stayed `running` after its attempt wrapper died, its `owned_processes` row stayed
`running`, and `hive daemon status --json` reported
`quiescence_capability: {eligible: false, reason: "agent_attempt_root"}`
indefinitely.

**Root cause:** `Dispatcher#reconcile_attempts` passes
`mutate_projects: owned_projects` to `Attempts::Reconciler#reconcile`. The
daemon's `ProjectGuard::Collection` only acquires guards for projects with
`daemon.enabled: true` (it retains a guard for a project disabled at runtime
until it drains, but a project already disabled at daemon start is never
enrolled). The paused project's attempt was therefore classified `:unowned`
every tick and never marked lost, so `reconcile_exited_owned_processes` (which
needs a settled attempt) never closed its row.

**Change:**
- `ProjectGuard::Collection#refresh!` remembers registered, disabled entries;
  `#with_maintenance_ownership(projects)` acquires their project guards for the
  duration of a block only, skipping owned, unknown, or foreign-held projects,
  and always releases them.
- `Reconciler#reconcile(maintain_projects:)` offers the projects of live
  attempts outside `mutate_projects` to that callback and reconciles the
  yielded subset while the guards are held.
- The daemon passes the callback when its ownership supports it; the one-shot
  runner's `ScopedOwnership` does not, so one-shot scope is unchanged. Dispatch
  gates (`owned_projects`, `project_enabled?`, the loss healer's enabled check)
  are untouched.

**Tests:** reconciler (dead attempt in a maintained project is lost and its
owned process then stops; live or foreign-held attempts untouched; no
maintenance request when everything is owned), project guard collection
(transient guard, foreign holder skipped, release on error), dispatcher
(maintenance reaches reconciliation, disabled project still not dispatched).
