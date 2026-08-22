# Project-local modules

Hive modules are reviewed, declarative packages installed independently for
each registered project. The same package contract now sits beneath managed
Honeycomb workflows, Patrol, and Architecture Patrol. Existing `hive workflow`,
`hive patrol`, and `hive refactor-patrol` commands remain compatibility
surfaces throughout Hive 0.x.

## Trust and package contract

Hive resolves modules only from a reviewed Honeycomb catalog entry pinned to a
full immutable catalog and source commit. It verifies canonical manifest bytes,
the manifest digest, every declared payload digest, and the complete regular
file inventory. Branches, tags, abbreviated revisions, arbitrary Git URLs,
local packages, undeclared files, links, special files, executable Ruby, and
unknown manifest keys fail before project mutation.

`hive-module/v1` packages may declare workflows, registered entrypoint hooks,
five-field schedules, bindings for exactly `task.completed`,
`pull_request.merged`, and `project.registered`, typed settings, permissions,
templates, and documentation. Package Ruby is never loaded. Current
`honeycomb-manifest/v1` workflow packages normalize losslessly into one
hook-free module, so they do not need republishing or manual migration.
Schedule syntax is validated with the same bounded five-field UTC cron parser
used by the daemon, so malformed ranges, steps, comma branches, and field
domains fail at package validation rather than after installation.

Native module workflow targets are validated and snapshotted at activation, but
execution currently fails closed. They will remain unavailable until task
metadata can pin module/run/snapshot provenance, admission can idempotently
attach one task to one hook run, and daemon/status recovery can resolve that
snapshot after update or uninstall. Registered entrypoints and explicitly
granted external commands are the executable target kinds in this delivery.

## Preview and lifecycle

Start with a no-write preview:

```bash
hive module install honeycomb/NAME --dry-run --json \
  --setting NAME=VALUE --hook HOOK=enabled --grant CATEGORY=VALUE
hive module update NAME --dry-run --json
```

The receipt binds the exact current and candidate generations, settings, hook
states, schedules/events, and each grant. Applying it requires `--yes`, the
matching `--receipt`, and every required non-interactive choice. A stale
receipt, changed catalog candidate, changed active pointer, omitted hook or
setting, permission expansion, new network host, or missing individual grant
fails without mutation.

```bash
hive module install honeycomb/NAME --yes --receipt RECEIPT ...
hive module enable NAME --dry-run --json
hive module disable NAME --dry-run --json
hive module uninstall NAME --dry-run --json
```

Activation stages an immutable generation behind a dispatcher barrier,
switches the pointer provisionally, validates structural prerequisites without
side effects, and either commits or restores the prior selection and hook
bindings. Hive retains the active and previous executable generations only.
Before pruning anything older, every nonterminal run must contain a complete
execution/configuration/grant snapshot. Runtime events, decisions, attempts,
retry state, artifacts, and Patrol ledgers live outside executable generations
and are never rolled back.

Disable stops new admission and closes pending retries without cancelling work
already running. Re-enable starts at the current high-water mark, so disabled
time is not replayed. Uninstall deactivates authority first, preserves history
and a tombstone, and treats later executable cleanup failure as a warning.

## Events, decisions, and attempts

The daemon is the only autonomous module dispatcher. Project events use a
strict fsynced ledger separate from fail-soft `Hive::Events` telemetry. Every
occurrence carries immutable project, time, source, event, and idempotency
identity. Hook admission serializes enabled state, cursor, deduplication,
concurrency, generation/configuration/grant identity, and attempt creation so a
replay or simultaneous trigger creates at most one permitted attempt.

Every evaluated occurrence writes a launch or skip receipt. Module hooks are a
first-class `hive-attempt` v3 subject and reuse the existing detached owner,
lease, heartbeat, bounded retry, receipt, and recovery machinery. A hook
failure records an attempt and retry; it does not roll back a structurally valid
installation. Capacity- or handoff-deferred retries wait one hour before
another admission attempt rather than spinning on every daemon tick, and the
pending reason and retry charge remain visible in module status.

## Read-only operations

```bash
hive module list --json
hive module status --json
hive module inspect NAME --json
hive module doctor NAME --json
hive module dry-run NAME --event schedule \
  --schedule '*/10 * * * *' --json
```

All five surfaces consume one redacted projection: active/previous provenance,
manifest/config/permission digests, hooks, schedules/events, effective
settings, secret binding names and availability, next trigger, latest
decision/attempt/retry/artifact/failure, and launch/skip rationale. They never
return secret values, raw environment, unsafe stderr, or unbounded logs.
Doctor reports interrupted activation or tampering but never reconciles it.
Module dry-run calls the pure trigger evaluator and writes nothing. This is
different from legacy `hive patrol --dry-run`, which retains its established
agent-launching and state behavior.

## Patrol discovery is native

Ordinary Patrol and Architecture Patrol are no longer packaged as first-party
modules. Their module manifests, adapters, migration ownership state, shadow
comparison, qualification reports, cutover/rollback commands, and daemon
coordinator have been removed.

Both discovery engines keep their native stores and reserve accepted findings
directly in the shared Patrol Fix `AdmissionStore`. Historical ordinary
findings use the explicit one-time `script/migrate_patrol_findings.rb`
importer; there is no runtime migration lane.

Public catalog promotion, tags, packages, releases, and deployment are separate
release-authorized work.
