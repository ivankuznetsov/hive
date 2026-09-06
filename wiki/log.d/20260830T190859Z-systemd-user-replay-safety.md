---
title: Make systemd user services offline-safe and replay-safe
date: 2026-08-30
---

- Removed system-manager network targets from all four shipped systemd-user
  templates and added a glob-based structural and user-mode parser gate.
- Made `Hive::UserService` serialize file and manager mutation under one
  real-home target lock, retain directional recovery journals, verify manager
  effects, and compact completed endpoints into applied receipts.
- Routed bot, web, babysitter, daemon, uninstall, migration cutover, takeover,
  and lifecycle actions through the shared owner while preserving their public
  command envelopes and unsupported-manager behavior.
- Preserved launchd completion at its verified loaded-job boundary and kept
  the public entrypoint clean-loadable without eager runtime-control-plane
  dependencies. Compact running status now loads its task-lease dependency
  explicitly instead of relying on incidental require order.
- Hardened review-discovered recovery boundaries: uninstall and purge stop
  before destructive cleanup on contention or ambiguity, cutover operations
  serialize through the same owner, rollback retains its direction, and
  activation cannot be verified by a process from an old cached definition.
- Kept manager-unavailable replay files unchanged, treated deactivating units
  with a live main process as not yet stopped, and carried actionable retained
  evidence diagnostics through lifecycle command failures.
- Added deterministic bot and babysitter retry checks plus a required real user
  manager scenario that passed locally with 232 runs, 1,060 assertions, and no
  failures, errors, or skips.
- Verified the default Hive test-file manifest directly with 14,270 runs,
  287,166 assertions, no failures or errors, and 12 portable skips. The root
  default task's `AgentCliRuntimeRuntimeTest` prerequisite failure had the same
  test, assertion, and source blobs on the untouched base and implementation
  revisions, satisfying the documented narrow baseline exception.
- Passed the exhaustive coverage gate with 1,751 process results and 100.00%
  line coverage (98,444 of 98,444 lines); the full instrumented Hive run also
  completed with 14,270 runs, 287,166 assertions, and no failures or errors.
- Documented local readiness versus remote-provider health, retry windows, and
  the non-destructive inspect-and-retry procedure in [[modules/user_service]].
