---
title: hive runtime
type: command
source: lib/hive/commands/runtime.rb, lib/hive/worktree.rb, lib/hive/runtime_control_plane/installation.rb, lib/hive/runtime_control_plane/database.rb, lib/hive/runtime_control_plane/activation_gate.rb, lib/hive/config.rb, schemas/hive-runtime-maintenance.v1.json
updated: 2026-11-28
tags: [command, sqlite, status, read-only, audit, bootstrap]
---

`hive runtime status [--json]` validates the current SQLite database read-only.
Healthy storage reports `active`; missing storage reports `absent`, exits 1 and
points to `hive setup`. Unsupported or corrupt storage returns a typed error.
The JSON contract is `hive-runtime-maintenance.v1`. `resume` is not supported.
For a current database, the result also includes a distinct read-only
`lifecycle` object (`phase`, `generation`, `revision`, and `admission_open`).
This does not replace installation health: storage remains `active` while work
is quiescing or paused. Missing storage reports `lifecycle: null`.
`hive runtime status` is not a backup acknowledgement. The increment-1 backup
contract requires a successful `hive daemon quiesce --json` followed
immediately by `hive daemon status --json` reporting the same paused generation
with valid proof and clear liveness.

On Linux, runtime status can inspect a read-only state root through this policy
only when the actual path has available, unambiguous `/proc/self/mountinfo`
metadata confirming the read-only mount. No sidecars uses an immutable
read-only connection; a readable WAL/SHM pair uses plain read-only inspection;
and either sidecar alone is refused. The command never
checkpoints, removes, repairs, or creates sidecars. A pair that needs forbidden
WAL-index recovery returns a read-only storage error instead of retrying with
immutable access.

`state_storage_read_only` normally directs the caller to `Use a writable,
accessible state root (HIVE_HOME).` An unpaired sidecar instead uses `Use a
writable state root (HIVE_HOME), or safely restore a matching WAL/SHM pair or
remove the stray sidecar after verifying no committed data will be lost.`
`state_storage_inaccessible` uses the general writable, accessible state-root
action. These access failures never recommend backup recovery. Confirmed
corruption and custody violations retain their existing codes and backup
action; in particular, a different-uid audit remains
`database_custody_invalid`. Auditing as another uid is unsupported.

Non-Linux platforms, including macOS, and Linux hosts with missing or ambiguous
procfs mount metadata cannot authorize immutable inspection. A typed read-only
failure there returns `state_storage_read_only` and the general action rather
than a successful status document. JSON storage failures use the
`hive-runtime-maintenance.v1` fields `runtime_code` and `next_action`. Because
runtime status shares this policy, it should not be recommended as a recovery
step for a path where the same inspection has already failed.

## Service-free bootstrap: `init`

`hive runtime init [--json]` (added 2026-11-23) is the one writing action. It
runs the runtime step of `hive setup` alone: `Installation.setup` creates and
migrates the database when it is missing (an existing one is validated, never
repaired), then `Hive::Config.sync_runtime_projects!` records every
registered project in it. The result is the `status` result with
`action: "init"`; it exits 0 when the runtime is `active`. Rerunning it keeps
the installation and its data. It installs no services and touches no agent
skills, qmd or web bundles, or project enrollment, so containers and hosts
without a user service manager can run durable attempts. A corrupt or
unsupported existing database fails at process start with the usual typed
error and backup action.

Why the project sync matters: registration syncs into the runtime only when
the database already exists. A project registered before it (for example by
`hive init` in a fresh container, or by `hive setup`'s own enrollment, which
runs before its runtime phase) had no runtime row. Its tasks then failed
dispatch with "attempt project identity is not registered for the task path".
`hive setup`'s runtime phase now runs the same sync. Tasks created while the
runtime was absent still have no task id (`TaskCounter.next_or_nil` returns
nil) and cannot be dispatched as attempts; recreate them after `init`.

## Audit listings: `projects` and `payloads`

Two more read-only actions exist for external audits. The consumer is
hivedev's read-only workspace audit, which mounts the state root read-only
after booting Hive in a container. `hive status --json` refuses that root and
`hive status --operational --json` lists only tasks.

- `hive runtime projects [--json]` reads the global registry
  (`Hive::Config.registered_projects`, `HIVE_HOME/config.yml` or the XDG
  config home) without loading project config or writing. Result:
  `registry_path` and `projects[]` with `name`, `project_id`, `path`,
  `real_path` (null unless the registry recorded one), the resolved
  `hive_state_path`, and the effective `worktree_root`. Rows the loader
  treats as invalid are omitted. A missing registry yields `projects: []`.
  An unreadable one fails with `runtime_code: "config"` and a registry
  `next_action`.
- `worktree_root` (added 2026-10-30) comes from a raw read of
  `<path>/.hive-state/config.yml` (`Config.read_project_config`: no
  validation, workflow loading or managed-store reconciliation) resolved
  through `Hive::Worktree.canonical_root`, the resolver `hive worktree` uses:
  the config's `worktree_root`, else `<HIVE_WORKTREE_BASE or
  ~/Dev>/<basename(path)>.worktrees`, then `File.expand_path`. A relative
  override therefore expands against the caller's current directory, exactly
  as Hive itself does. A missing, unreadable or invalid-YAML config.yml, a
  non-string `worktree_root`, or an unexpandable value (unknown `~user`)
  yields `worktree_root: null` plus a short `worktree_root_error` for that
  project only; the listing still succeeds. Auditors should treat a null root
  as incomplete evidence.
- `hive runtime payloads [--json]` reads every `payload_references` row
  through `Database#payload_references_snapshot`. That method uses the same
  diagnostics and inspection policy as status: readonly, immutable only on a
  confirmed read-only mount, and no WAL, migration or sidecar creation.
  Result: `phase` (`active`/`absent`), `payload_root`
  (`Hive::Paths.runtime_payload_root`) and `payloads[]` with `payload_id`,
  `kind`, `state`, `task_id`, `attempt_id`, `relative_path`, `sha256`,
  `bytes` and `path`. `path` is `File.expand_path(relative_path,
  payload_root)`. It is reported, not validated, so the auditor can do its
  own containment check. Missing storage is `phase: "absent"` with
  `ok: true`, exit 0 and an empty list. Corrupt, unsupported or
  unconfirmed-read-only storage fails with the usual runtime error envelope.

Both actions return `ok: true` and are listed in
`ActivationGate.strict_no_write_route?`, so process bootstrap does no
scheduler reconciliation or other writes for them. The schema change is
additive: new `ProjectsPayload`/`PayloadsPayload` branches, still v1. The
optional per-project `worktree_root`/`worktree_root_error` pair is also
additive; the schema requires the error exactly when the root is null.

`Installation.setup` serializes explicit setup, builds a complete current database
privately and publishes without replacing an existing destination. Repeated setup
validates the existing database and preserves identity and data. Startup validates
existing storage without creating or migrating it; fresh commands that do not
require runtime storage remain available before setup.

No cutover manifests, historical import, retired-writer sealing, service replay or
activation phase state machine remains. Current schema/application identity,
installation identity, private storage custody and integrity validation remain.
Historical activation columns remain inert in the current schema so existing
current databases do not require another conversion.

Tests: `test/unit/runtime_control_plane/installation_test.rb`,
`activation_gate_test.rb`, `database_test.rb`, `test/unit/commands/runtime_test.rb`,
and the real-mount `test/integration/status_read_only_test.rb` gate.

## Runtime storage attributes

Use the service account and its environment to resolve the live database.
A nonempty `HIVE_HOME` selects the state root directly. Otherwise it is
`$XDG_STATE_HOME/hive`, defaulting to `~/.local/state/hive`. The usual file is
`runtime-control-plane.sqlite3`. An explicitly supplied database path uses its
actual parent. Doctor reports the resolved paths in `runtime/sqlite-storage`.

| Outcome | Evidence and operator action |
| --- | --- |
| `healthy` | All applicable existing btrfs paths have C. The directory, DB and each present `-wal`, `-shm` and `-journal` have independent evidence. |
| `warning` | At least one btrfs path lacks C. Read the affected paths and any additional inconclusive probes before planning a move. |
| `indeterminate` | Hive could not establish the filesystem or flags. Check path access and the reported probe. On Linux verify that GNU `stat -f` and `lsattr -d` work as the service user, then rerun doctor. |
| `not_applicable` | The paths are on known non-btrfs storage or this is a non-Linux platform. |
| `uninitialized` | The state directory is absent. An existing directory can be checked before the DB exists, including any orphaned sidecars. |

On a provisioning run, setup attempts preparation after agent setup permits
it. Direct `Installation.setup` (including `hive runtime init`) checks before
the activation lock creates its file. It publishes a database migrated by
`Database` in a staging directory under that root. On first daemon start, Hive
checks before creating logs or acquiring the lock. The daemon still requires
the normal explicit database initialization. Readers, low-level migrations,
quiescence upgrades and diagnose-only setup perform no attribute preparation.

On confirmed btrfs, Hive sets and verifies C on a new or empty eligible
directory so newly created files inherit it. A populated directory, including
one with only a hidden lock file, requires manual migration if flags need to
change. A failed probe or preparation is advisory. NOCOW disables data
checksums and compression for affected files, including other new files that
inherit the directory flag. This loses checksum-based mirror repair of their
data. Snapshots may still trigger CoW. The attribute check measures no latency
or throughput. See [btrfs scrub](https://btrfs.readthedocs.io/en/latest/Scrub.html),
[compression compatibility](https://btrfs.readthedocs.io/en/latest/Compression.html#compatibility)
and [chattr(1)](https://www.man7.org/linux/man-pages/man1/chattr.1.html).

## Btrfs NOCOW migration

Use this manual procedure for an existing installation. Keep the original
tree intact and keep admission closed through copy, validation and swap.

1. **Identify the installation and plan the backup.** In the effective service
   environment, record the resolved root, DB path, installation ID from
   `hive runtime status --json`, ownership and permissions. Choose an external
   backup location. Make a provisional inventory of *every* root being
   replaced, including hidden files, runtime payloads, daily digests, workflow
   publication objects and receipts, fences, and unrelated files. This applies
   equally to default XDG, custom XDG and shared `HIVE_HOME` installations.
   Writers may still add files or payload references at this point.
2. **Establish an idle window.** Follow the [Increment-1 idle backup procedure](../operating.md#increment-1-idle-backup-procedure)
   and [Increment-1 quiescence boundary](daemon.md#increment-1-quiescence-boundary).
   Stop external submissions, run `hive daemon disable --all`, inhibit
   automatic restarts, stop the daemon, bot, babysitter and web services and
   let outstanding attempts finish. Separately stop and verify readers and
   writers of payloads, digests, publication state and every other file outside
   the DB proof. Abort the replacement if their consistency is uncertain.
   Daemon absence, a descriptor scan and an eligibility verdict each leave
   the required quiescence acknowledgement outstanding.
3. **Bind the final inventory to the paused generation.** Run
   `hive daemon quiesce --json`. Require `paused: true`, generation G,
   `checkpoint.complete: true` and the bound proof for G. With external
   writers verified stopped, rescan all source roots. Build the **final
   manifest for G** with each non-database path, file type, owner, permissions
   and, for regular files, size and hash. Include required fences and receipts.
   A receipt written between the provisional inventory and shutdown belongs
   in this final manifest. Run `hive runtime payloads --json` anew against
   the paused source, including references added just before quiescence.
   Record the source and intended destination of every retained payload and
   verify its size and SHA-256 against the DB. Store these records with the
   external backup, outside both trees.

   Immediately before copying, inspect `hive daemon status --json` and require
   `lifecycle.phase: paused`, the same G, `lifecycle.proof.valid: true` and
   `lifecycle.liveness.clear: true`. A quiescing result, changed generation,
   incomplete checkpoint or missing/stale proof invalidates the manifest and
   any copy. Retry quiesce, fetch payload references again, rebuild the
   manifest and restart copying. If another writer restarts or source contents
   change after finalization, reestablish consistency and repeat those steps.
   A precheck refusal with admission open authorizes no copy. A refusal with
   admission closed needs explicit retry or resume. A manual SQLite
   checkpoint or backup command cannot establish Hive's generation proof.
4. **Prepare empty storage and copy.** Create a fresh private destination on
   the intended btrfs filesystem. Check it with `stat -f`, set
   `chattr +C "$destination"` and verify C with `lsattr -d "$destination"`
   before placing data there. Retain an external coherent backup of the
   checkpointed DB, its matching `runtime-quiescence-proof.json`, and all
   state in the final manifest. Copy the DB and matching proof into new
   files using `cp --reflink=never` and preserve ownership and private modes.
   Verify btrfs and C on the actual destination DB. Keep the original WAL and
   journal intact. Committed transactions can reside in a WAL, and old
   sidecars must never be combined with a replacement DB. The successful
   checkpoint and proof authorize the DB/proof pair only. Copy the separately
   stopped contents from the **final** manifest to their recorded paths,
   preserving types, ownership, permissions and required fence files.
   See [SQLite WAL](https://www.sqlite.org/wal.html).
5. **Validate before swapping.** Keep the original usable and retained if
   any check fails. Using the candidate environment and read-only checks,
   validate SQLite integrity and foreign keys, application and schema identity,
   the original installation ID, paused generation G and its matching proof.
   `hive runtime status --json` and `hive daemon status --json` expose these
   installation and lifecycle checks. Close validation connections and inspect
   any resulting sidecars. Keep the proof in place and avoid lifecycle
   mutations on the candidate. Compare every non-database entry against the
   final manifest, including types, ownership, private permissions, and
   regular-file sizes and hashes. Account for unexpected destination entries.
   Verify every retained payload for G at its recorded destination by size
   and SHA-256. A missing or mismatched publication receipt blocks the swap
   even when the DB, proof and every payload pass.
6. **Swap while admission is closed.** Recheck the source's paused generation,
   proof and clear liveness and verify external writers remain stopped. Close
   all processes and descriptors holding old storage or fence inodes. Stage on
   the same filesystem when using rename. Replace the complete directory, or
   point every service consistently at the validated dedicated location.
   Preserve all state-root contents for every layout. `XDG_STATE_HOME` takes
   effect only when `HIVE_HOME` is unset or empty. Confirm the matching proof
   at its effective path beside the DB and all stable fences before restarting.
7. **Resume from the destination.** Run `hive daemon resume --json` explicitly.
   Require `admission_reopened: true`, then check `hive daemon status --json`
   for `lifecycle.admission_open: true` and `hive runtime status --json` for
   an active, healthy installation with `result.lifecycle.admission_open: true`.
   Check each service restart outcome and run `hive doctor`. Restore intended
   dispatch and service settings deliberately after successful reconciliation.
   A healthy database can still be paused, and individual restarts can fail
   after admission reopens. Retain the old coherent installation until all
   checks pass. After new writes, reconcile them before attempting rollback.
