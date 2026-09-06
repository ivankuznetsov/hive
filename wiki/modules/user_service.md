---
title: UserService
type: module
source: lib/hive/user_service.rb, lib/hive/user_service/, lib/hive/commands/service_installer/, examples/systemd/
created: 2026-07-26
updated: 2026-08-30
tags: [module, services, systemd, launchd, recovery, offline, boundaries]
---

# UserService

`Hive::UserService` is the sole Hive owner for a per-user service definition,
its installed file, and the corresponding systemd-user or launchd lifecycle.
Daemon, babysitter, bot, web, setup, init, migration cutover, status, and
uninstall remain thin command adapters around this boundary.

## Linux user-unit invariant

Every shipped `examples/systemd/*.service` file is a user-manager unit. The
whole glob, including future templates, must:

- install under `WantedBy=default.target`;
- omit `network.target` and `network-online.target` from `After=`, `Wants=`,
  `Requires=`, `BindsTo=`, `PartOf=`, and install targets; and
- parse under `systemd-analyze --user verify` after its example `ExecStart=` is
  rendered to a real executable.

The network targets are system-manager concepts and are not a remote-readiness
contract for a per-user manager. Hive units therefore start while the machine
is offline. Connectivity retry belongs to the application, while systemd owns
one local main process and restarts it only after a process failure.

An `active` unit proves that its local process is alive. It does not prove that
Telegram, GitHub, a Git remote, or any other provider is healthy.

## Public entry point

Require `hive/user_service` and construct a service with a
`Hive::UserService::Definition`:

- `Definition` carries the platform, service identity, canonical target path,
  desired content, and launchd label.
- `Status` reports no-follow file identity plus the manager's tri-state
  availability, enablement, running state, and bounded diagnostics.
- `Plan` is an immutable apply or remove decision bound to the exact definition
  and observation that produced it.
- `Result` keeps the existing typed outcome, backup path, restart flag, final
  status, error class, and bounded diagnostics. Command adapters retain their
  existing text and JSON schemas.

`inspect`, `plan`, `plan_remove`, and `inspect_recovery` are read-only. `apply`,
`remove`, `purge`, `start`, `stop`, `restart`, and `takeover` enter the same
target ownership boundary. A plan is revalidated after ownership is acquired;
stale observations and fabricated force or manager flags do not mutate state.

## Exclusive ownership

Coordination lives under the real home that owns the unit path:

```text
<real-home>/.local/state/hive/user-service/
```

Records are keyed by a digest of the full canonical target path and repeat that
path inside their content. `HIVE_HOME`, `XDG_STATE_HOME`, and other application
state overrides cannot split ownership of one real unit. Directories and
records must be owner-controlled, regular, no-follow, and mode-safe.

The target lock has a short bounded acquisition window (currently 250 ms). Its
holder record includes PID, boot identity, process-start identity, target, and
acquisition time. A live or unprovable holder returns the existing failed
outcome with retry guidance and no unit, backup, journal, or manager mutation.
A later owner can reclaim a record only when the recorded process is proven
dead, from another boot, or PID-reused. Manager work remains lock-owned; its
separate timeout is the unit's `TimeoutStopSec` plus a five-second margin, so a
610- or 900-second graceful drain is not mistaken for abandoned ownership.
The first coordination-directory creation is serialized by a bootstrap fence
in the real home, after which a target-specific guard protects lock-record
inspection and reclamation. Timed-out production manager commands are
terminated as a process group and synchronously reaped before ownership is
released, so they cannot mutate systemd later from outside the lock.

All Hive service-manager mutations route through this owner. This includes web
start/stop/restart and bundle refresh, babysitter detached-process takeover,
migration cutover restarts, install/upgrade, uninstall/purge, and ordinary
lifecycle actions. The babysitter's ownership-aware 600-second stop occurs
inside the install transition before the manager starts its replacement.

## Durable apply and replay

Filesystem publication and a service manager do not offer a native joint
transaction. UserService instead makes durable intent authoritative until a
complete endpoint is freshly observed:

1. Acquire the canonical-target lock, reconcile any pending transition, and
   re-inspect the bound file/manager observation.
2. Persist a versioned journal containing the service and target identity,
   prior content and manager projection, desired digest, exact manager intent,
   backup identity, direction, and phase before visible mutation.
3. Create one collision-safe operator backup for an authorized forced content
   change, revalidate it before publication and commit, then publish through a
   descriptor-relative compare-and-swap. An operator file created, replaced,
   or edited after inspection is preserved and leaves recovery evidence rather
   than being overwritten or unlinked.
4. Record and verify the manager reload separately, then resume the recorded
   enable, restart, or takeover intent. A command's exit status is evidence,
   not truth: fresh load state, fragment path, reload need, enablement, active
   state, main PID, and process-start observations decide the result.
5. Persist verification and commit, write one compact applied receipt, then
   remove the pending journal.

Replay rolls forward by default and never creates a second backup. If the
recorded desired operation cannot safely complete, UserService durably selects
rollback before restoring anything. A fresh process stays in that rollback
direction until prior file and manager state are freshly verified. Merely
seeing prior bytes is not enough to clear the journal.

A manager action that mutates and then reports failure can still finalize when
the desired projection is proven. If neither the prior nor desired endpoint is
provable, the journal is retained and unrelated mutation fails closed. Public
success is never based only on desired bytes being present.

An enabled install of a matching legacy unit with no receipt performs one
conservative recorded restart, verifies the platform's managed endpoint, and
writes a receipt. Later applies are true no-ops. Operator backups remain beside
the unit as `<path>.bak-<UTC timestamp>` with an exclusive disambiguator when
two changes share a timestamp; replay-private prior content stays in the
journal.

Explicit `start`, `stop`, `restart`, and `takeover` calls use their own durable
phases under the same target lock. Replay first observes whether the recorded
effect already completed; in particular, restart/takeover compares the prior
and current process identities before deciding whether another action is safe.

## Verified endpoint modes

| Mode | Completion condition |
|------|----------------------|
| Managed | Desired file plus an available manager reporting the unit enabled. Linux also requires the canonical target loaded with no pending daemon reload and a running process with live identity; launchd completion is the loaded job registration because command adapters separately own process health and readiness. |
| Intentional no-autostart | Desired file plus a `no_autostart` receipt; no manager command |
| Unsupported autostart | Desired file plus an `unsupported_autostart` receipt after a conclusive manager-absence probe |
| Restored prior | Prior file and prior manager projection freshly verified after durable rollback selection |
| Ambiguous | No success; journal retained, with no unrelated overwrite or cleanup |

`remove` and `purge` acquire the same lock and finish pending install recovery
first. Verified stop/disable, unlink, and reload remove the journal and receipt.
Ambiguous removal retains both. A repeated verified removal remains idempotent.

## Manager availability

Manager inspection has three internal states:

- `available` — the user manager can be queried and may enter a managed
  transition;
- `conclusively_absent` — the executable is missing/raises `ENOENT`, or Linux
  produces the compatibility-pinned non-zero `systemctl --user --version`
  probe; a clean install may publish a filesystem-only unsupported-autostart
  receipt; and
- `indeterminate` — every other probe failure. A clean operation fails before
  mutation; manager loss during a journaled operation retains that operation
  for replay.

An intentional `autostart: false` apply is separate from unsupported
autostart and never contacts the manager. A later autostart-enabled invocation
with an available manager records and performs the missing action once.
Launchd keeps its existing public outcomes behind the same lock and replay
boundary.

## Offline and reconnect behavior

| Service | Offline behavior and next retry |
|---------|---------------------------------|
| Bot | The Telegram transport absorbs transient polling failures and keeps the supervisor alive. The supervisor waits `POLL_FAILURE_BACKOFF_SEC` (currently 1 second), then starts the next poll; recovery time also includes that request's response time. |
| Babysitter | A GitHub provider failure is logged for the current project tick and does not exit the dispatcher. The next dispatch retries it at the configured project interval; the default is 600 seconds (10 minutes). |
| Web | Rails remains locally startable and its local readiness endpoint is independent of remote providers. A failed GitHub, clone, or other remote operation reports its own failure to the caller, which retries that operation. |
| Daemon | The local dispatcher remains available offline. Individual remote work reports its own provider failure and follows that operation's retry/recovery policy. |

Configuration, credential, executable, and Ruby-environment failures are not
connectivity failures and may stop a service. Genuine process crashes remain
subject to each unit's `Restart=` and `StartLimit*` policy.

## Non-destructive recovery procedure

When an install reports busy, retained recovery, or indeterminate manager
state:

1. Inspect the target and manager without editing them (`stat UNIT`,
   `systemctl --user status SERVICE`, and `systemctl --user show-environment`).
2. Inspect, but do not unlink or rewrite, the matching owner-private lock,
   journal, and receipt under `~/.local/state/hive/user-service/`.
   `UserService#inspect_recovery` reports their exact paths for a constructed
   definition.
3. If the recorded holder is live, let it finish. If it is dead or PID-reused,
   retry the original Hive command; automatic identity proof performs the only
   routine reclamation.
4. Restore a functional user manager, then retry the same install, uninstall,
   or lifecycle command. The recorded direction and action resume under the
   lock.
5. If identity, schema, current bytes, or manager projection still cannot be
   proven, preserve the evidence and investigate. Deleting a journal or lock
   is not a normal repair procedure.

## Verification

The contract is pinned at complementary layers:

- `test/unit/examples_systemd_user_templates_test.rb` parses raw directive
  lines for every shipped glob match, checks `WantedBy=default.target`, and in
  the required gate verifies rendered copies with a real executable.
- `test/unit/user_service/user_service_test.rb` covers tri-state probes,
  contention/liveness, collision-safe backups, receipts, phase and directional
  replay, mutate-then-fail manager evidence, legacy adoption, removal, and
  fail-closed records.
- focused manager, transaction, journal, receipt, status, and plan tests pin
  bounded process execution, strict record schemas, pathname binding,
  bootstrap fencing, and immutable observation identities.
- shared plus bot, web, babysitter, daemon, setup, migration, and uninstall
  tests pin adapter schemas and the single mutation owner.
- `test/integration/systemd_user_service_offline_test.rb` installs a unique
  unit through UserService under a real user manager. It proves multiple
  offline retries, bounded reconnect without repair commands, one stable
  `MainPID`, one live cgroup process, one success record, unchanged reapply,
  losing contention, and residue-free teardown.
- `bundle exec rake test:systemd_user_service` is a required, non-skipping
  Linux CI job after explicit user-session provisioning. The integration file
  also enters exactly one of the ordinary six coverage shards, where it skips
  portably when the real-manager gate is not declared.
