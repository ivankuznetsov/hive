---
title: hive refactor-patrol-reset
type: command
source: lib/hive/commands/refactor_patrol_reset.rb, lib/hive/refactor_patrol/job_store_fresh_start.rb
created: 2026-07-30
updated: 2026-07-30
tags: [command, architecture-patrol, jobstore, reset, recovery]
---

**TLDR**: `hive refactor-patrol-reset PROJECT --confirm` makes one explicit
choice to abandon an obsolete Architecture Patrol v2 jobs backlog. Hive stops
and verifies the current profile daemon, atomically archives the exact opaque
`v2/jobs` directory, starts an empty v3 JobStore, and restarts only the daemon
it stopped. Hive never reads, converts, imports, or silently deletes v2 jobs.

## Usage

```bash
hive refactor-patrol-reset PROJECT --confirm
hive refactor-patrol-reset PROJECT --confirm --json
```

`PROJECT` must resolve to one exact registered project whose stored canonical
path still matches the filesystem. `--confirm` is mandatory and states the
product consequence directly: the archived v2 backlog will not appear in v3.
There is no all-user mode, package hook, install-time sweep, timer, or automatic
constructor fallback. Another OS user runs the command under their own Hive
profile if they choose the same reset.

## Atomic boundary

The reset owns only:

```text
<hive_state_path>/refactor_patrol/v2/jobs
```

It first places a canonical transaction marker beside that directory, then
uses a single filesystem exchange to swap the public `jobs` name with the
marker. The old directory survives unchanged as:

```text
<hive_state_path>/refactor_patrol/v2/.jobs-v2-archive-<nonce>
```

The completion receipt is outside both replaceable generations at:

```text
<hive_state_path>/refactor_patrol/jobstore-fresh-start.json
```

Every other released-v2 owner remains in place, including manifests, families,
reconciler state, results, runs, logs, quarantines, and the separate global
terminal-proof catalog. The reset does not enumerate the archive or reconstruct
occurrence identities from it.

## Writer fencing and restart

The command first takes a stable profile-wide daemon-activation lock. New
daemon starts take that same lock and retain it until their exact process
generation has published operational runtime readiness, so startup cannot
cross the reset.

If the current profile daemon is running, the command captures its exact PID,
process start time, supervised descendant tree, and child process groups. It
uses the normal graceful stop, requires the daemon's generation-bound shutdown
acknowledgement, and verifies that every captured writer is gone. Daemon
quiescence deliberately precedes the project effect lock: shutdown completion
may still need to settle an admitted Patrol publication.

After the daemon drains, the command takes the existing Patrol migration/effect
lock exclusively. Current effect gateways take it shared from final admission
through send or reconciliation, so the reset waits for every admitted effect
and prevents another from crossing the archive transaction. Under that lock,
the storage boundary repeats an independent daemon PID/start-time fence, then
keeps the lock through exchange, empty-v3 admission, and receipt publication.
Failure to prove either fence aborts with recovery instructions.

The command releases both locks before restarting, avoiding a child-start
deadlock. Its `ensure` path restarts only a daemon it stopped, and waits for the
new live generation's operational readiness rather than accepting a PID file
alone. An already stopped profile remains stopped.

## JSON contract

`--json` emits `hive-refactor-patrol-jobstore-reset.v1`. Successful reset and
idempotent no-op documents report the exact project identity, `changed`,
generation names, target schema version, transaction id, archive path, and
receipt path. Confirmation, configuration, fencing, unavailable-runtime, and
internal failures emit the same schema's typed error arm; no failure can look
like a successful fresh start.

## Statuses and refusal cases

`hive daemon status --json` exposes the same generation state under
`job_store_resets.projects[]`:

- `fresh`: neither generation exists; the first v3 mutation may initialize v3.
- `current`: v3 is admitted, either as a fresh store or by a completed reset.
- `reset_required`: released `v2/jobs` is still a directory.
- `reset_incomplete`: the atomic archive exchange completed, but the v3
  namespace or completion receipt still needs the same command to resume.
- `conflict`: non-empty v3 state and released/incomplete v2 state coexist.
- `error`: a malformed registration or generation record was isolated in
  status reporting.

The reset is idempotent after completion. It refuses a non-empty v3 store,
foreign entry types, malformed/noncanonical markers or receipts, missing
archives, an archive whose public marker is missing, changed transaction
bindings, live writers, and filesystems that cannot provide atomic exchange.
These conditions require operator repair; Hive does not guess which data to
keep.
