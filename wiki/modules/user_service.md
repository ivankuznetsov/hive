---
title: UserService
type: module
source: lib/hive/user_service.rb, lib/hive/user_service/
created: 2026-07-26
updated: 2026-07-26
tags: [module, services, systemd, launchd, boundaries]
---

# UserService

`Hive::UserService` is Hive's platform-neutral boundary for per-user service
files and their systemd-user or launchd lifecycle. Hive remains its first and
primary consumer through thin daemon, bot, web, setup, init, status, and
uninstall adapters.

## Public entry point

Require `hive/user_service` and construct a service with a
`Hive::UserService::Definition`. The supported public values are:

- `Definition` — platform, service identity, target path, desired content, and
  launchd label. Content may be omitted for remove-only use.
- `Plan` — an immutable apply or remove decision bound to the definition and
  the exact file and manager observation used to make it.
- `Status` — content state, no-follow file identity, manager availability,
  enabled/running observations, and diagnostics.
- `Result` — typed outcome, backup path, restart flag, final observed status,
  error class, and bounded typed diagnostics. Raw exception messages are not
  exposed across the boundary.

`inspect` and `plan` are non-mutating. Apply and remove re-inspect the same
observation surface before mutating; a changed file or manager state returns a
stale result without proceeding. They also recompute the plan decision from
its bound status, so callers cannot fabricate force, removal, or
manager-observation flags around those checks.

## Ownership boundary

UserService owns:

- no-follow inspection of a unit or plist;
- drift classification and stale-plan rejection;
- atomic writes and timestamped force backups;
- systemd-user reload/enable/restart/disable operations;
- launchd load/unload operations;
- safe, idempotent removal and final-state reporting.

Hive adapters continue to own:

- daemon, bot, and web templates;
- executable and install-channel resolution;
- web environment rendering;
- command messages, JSON envelopes, prompts, and service nouns;
- the daemon 900-second restart warning;
- foreground process shutdown and global uninstall/purge ordering.

The boundary supports Linux systemd user services and macOS launchd only. It
does not claim a filesystem/service-manager transaction: partial outcomes name
the completed mutations and report the final state callers can retry from. If
a backup succeeds but replacement fails, the failed result still reports that
backup path. A present `systemctl` binary without an available user manager
writes the unit but performs no manager mutation and reports
`autostart_unavailable`.

## Internal collaborator

`Hive::UserService::Manager` is private to the component. External consumers
must use the facade rather than constructing manager adapters directly. This is
enforced by `config/component-boundaries.yml`.

## Verification

Focused coverage lives in:

- `test/unit/user_service/user_service_test.rb`
- `test/unit/commands/service_installer/base_test.rb`
- daemon, bot, and web service-installer tests
- `test/unit/commands/uninstall_test.rb`
- `test/unit/component_boundaries_test.rb`
