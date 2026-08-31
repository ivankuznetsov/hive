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
- Added deterministic bot and babysitter retry checks plus a required real user
  manager scenario that passed locally with 231 runs, 1,040 assertions, and no
  failures, errors, or skips.
- Documented local readiness versus remote-provider health, retry windows, and
  the non-destructive inspect-and-retry procedure in [[modules/user_service]].
