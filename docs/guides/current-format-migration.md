# Move an older Hive installation to the current format

Hive reads and creates only current formats. It does not run historical migrations
on startup or update. `hive migrate` and `hive runtime resume` have been removed.
An existing healthy current runtime database needs no conversion or cutover manifest.
Use `hive runtime status --json` to check it. A fresh installation uses `hive setup`.

## Additive command-receipt extension

The base database remains schema v1. Ordinary `hive setup` and
`hive setup --yes` initialize or validate only that base and can refresh
services without installing command receipts. The extension is requested only
with `hive setup --install-command-receipts`; add `--yes` when unattended
consent is required. `--yes` alone never opts into the extension.
`--no-bootstrap` remains zero-mutation diagnosis even when combined with the
flag. An installed extension is retained when later setup omits the flag.
Namespace keyed intake is a separate, disabled-by-default project config
switch; it neither installs nor removes schema.

Migration 002 adds tables and indexes only. It does not alter or delete any
existing object or row, including `schema_info` and installation identity. Its
blast radius is the one shared host control-plane database: every Hive project
and service using that database sees the objects even while every intake gate
is disabled. Unmodified pre-compatibility binaries reject the added objects.

Production installation therefore requires a published, retained rollback
package whose exact version, authenticated HTTPS location, and SHA-256 are
pinned in `CommandSchemaInstallation::PUBLISHED_ROLLBACK_PACKAGE`. This Tier A
source intentionally leaves those production coordinates unset; setup refuses
the opt-in with CONFIG before *any* setup mutation. Until Tier B publication,
run `hive setup` or `hive setup --yes` without
`--install-command-receipts` for a base-only install or refresh.

Code-complete rollback handoff status for this checkout:

- pinned prior revision: `882b8e9ead2f9cf5321b158fe47648e6a01a2fca`
- extension manifest SHA-256:
  `a108a7018f7e4b0d9e83674bda6457ac0d2c875539c1a7ecd8a95277546b4a3d`
- compatibility patch diff:
  `docs/implementation/command-receipt-compatibility.patch`
- compatibility patch SHA-256:
  `fdfd638d7b092f09583960dfcc0ae505037f3499e34f60a99ef8bd3e7d289c2e`
- externally retained candidate output (not committed):
  `hive-cli-command-receipt-compat-candidate.gem`
- candidate SHA-256:
  `cf7eae51b26bdace854d4a40ab681c53ff67aebb1670fc939310ff7fce3ba712`
- isolated packaged rollback drill:
  `docs/implementation/command-receipt-compatibility-proof.md`
- published version/location/SHA-256: pending maintainer release authorization

Published retained coordinates remain an activation blocker and must never be
replaced with the local candidate. For the Tier A candidate drill, point to the
retained build output, verify it before installation, and abort on any mismatch:

```sh
candidate_sha256='cf7eae51b26bdace854d4a40ab681c53ff67aebb1670fc939310ff7fce3ba712'
candidate_gem=${HIVE_COMPAT_CANDIDATE_GEM:?set to the retained candidate path}
printf '%s  %s\n' "$candidate_sha256" "$candidate_gem" | sha256sum --check --strict &&
  gem install --install-dir "$PWD/hive-compat-prefix" "$candidate_gem"
```

Before extension installation, stop Hive daemon, babysitter, web, and all
external writers; verify their PID/start identities are absent; take the normal
private external backup of the database plus WAL/SHM and project markers. The
installer repeats stopped-writer checks under the activation lock. Backup is
disaster recovery, not the ordinary rollback mechanism.

After Tier B qualification, replace the placeholders above with the exact
published package coordinates pinned by the build, repeat checksum verification
from that retained location, install the extension release, and enable projects
one at a time only after capacity and maintenance verification.

Routine rollback first stops delivery and drains/fences keyed effects because
the compatible older runtime does not execute their protocol. Install the exact
checksum-verified compatibility package, leave the extension tables, database
identity, and receipts intact, and exercise ordinary attempt/lease/dispatch
reads and writes. Re-upgrade with the exact newer package and verify a saved
receipt replays. Arbitrary pre-compatibility versions are unsupported rollback
targets, and rollback of the binary also rolls back unrelated code changes
since the pinned revision.

For an older installation, give your agent the prompt below. This is a supervised,
one-off conversion of the state you choose to retain, not a supported migration
engine. Keep the backup until you have checked the resulting tasks.

## Agent prompt

Help me move this Hive installation to the current checkout's formats.

1. Inspect the installed executable and its install manager, the target checkout,
   `hive runtime status --json`, configured XDG/HIVE_HOME locations, project registry,
   and every registered project's actual state path. Read the target's current
   schemas, config defaults, workflow descriptors, TaskMeta, TaskJournal,
   TaskCounter and runtime registration APIs. Do not assume fixed home paths.
2. Stop Hive services and confirm no stage agents, task owners, or external workers
   are still writing. Inventory each task's stable id, project, workflow, stage,
   completion state, PR URL/head, worktree, dependencies, markers, journal and
   evidence. Report missing projects, duplicate ids and ambiguous state; do not
   infer that a missing task is complete.
3. Make and verify a private external backup of global config/state/data, every
   project state directory including its Git history, and relevant worktrees.
   Preserve secrets without printing them. Do not overwrite or delete the backup.
   Work on copies first and show the exact conversion inventory before replacing
   live state. Never run two Hive versions against the same live storage.
4. Retain a healthy current SQLite database unchanged. If status reports the pinned
   pre-quiescence layout or one of the exact supported quiescence-era revisions, inspect
   `Hive::RuntimeControlPlane::QuiescenceUpgrade` in the target checkout and invoke
   its `#call` Ruby API directly under supervision, with an ownership verifier that
   returns true only after step 2 has proved every Hive service and legacy worker is
   stopped. This helper is intentionally not a `bin/hive` action: it takes the
   quiescence operation and writer fences, rechecks the exact fingerprint under
   those fences, and invalidates any old paused proof before its first schema write.
   A quiescence-era source must already be `quiescing` or `paused`; conversion
   preserves its generation, deadline, interrupted-attempt references, and
   installation/attempt/payload identities while leaving admission closed in
   `quiescing`. Run explicit `hive daemon resume` only
   after validating the converted database. The helper invalidates any old
   quiescence proof; a pre-upgrade paused acknowledgement never authorizes a
   post-upgrade copy. After resume, obtain a new quiesce acknowledgement and
   same-generation daemon-status confirmation before any backup. If the helper
   rejects the fingerprint, archive the old runtime together with its WAL/SHM
   after all writers stop, and
   initialize a fresh current runtime with services still stopped.
   `Hive::RuntimeControlPlane::Installation.setup` is the explicit initializer;
   inspect its current API before calling it. Never alter schema hashes or version
   fields to make old tables look current. Keep historical usage and attempts in
   the backup unless I explicitly request a separate verified conversion.
5. Convert only the task/config state I choose to keep. Use canonical
   `review.reviewers`, `claude.mode`, and `budget_usd.finalize` /
   `timeout_sec.finalize`; remove retired policy keys. Move an old global config
   into the explicitly selected current config location only after resolving any
   collision. Use each workflow's actual descriptor to map old stage folders;
   never guess from stage numbers or overwrite an existing task directory.
6. Preserve ids, dependency edges, names, original completion timestamps, borrowed
   PR ownership, journals and evidence. If a task lacks an id, allocate a unique
   one through current APIs. Register projects/tasks through current APIs and seed
   `Hive::TaskCounter.seed_at_least!` above the highest retained id across all
   projects. Rebuild derived indexes only from verified source records. Never
   fabricate successful attempts, completion times, approvals, provider usage,
   receipt signatures, or outcome-evidence acceptance to pass validation.
7. For retired Bench descriptors or obsolete managed workflow pins, archive the
   old descriptor/instructions and explicitly install the current workflow.
   Preserve tasks that cannot be mapped as offline historical evidence. Use
   current workflow install/update for supported current package upgrades.
   Re-run any required planning/review/artifact stage whose old evidence cannot
   meet today's contract; do not silently bless it. Do not resume old dispatch
   requests or recreate uncertain external side effects.
8. Validate config, runtime identity/integrity, workflow resolution, every retained
   task's id/stage/dependencies, and current JSON schemas. Compare the before/after
   inventory and account for every task. Run a new disposable task far enough to
   prove task-id allocation, journal creation and stage discovery. Report exactly
   what was preserved, archived, reset, or still needs a decision.
9. Restart only the services I previously used, after validation and approval of
   the concrete conversion. Verify fresh status and task inspection. Do not
   publish, merge, close PRs, deploy, or advance tasks as part of conversion.

## Maintainer policy

Keep one current contract per public schema name. Update repository producers,
readers and tests together. Retain strict schema and storage validation, ordinary
crash recovery, current workflow-package upgrades, and read-only warnings for
unrecognized task folders. Those warnings expose `legacy_state_guide` rather than
an executable migration command. Historical source formats belong in this guide
and external backups, not in automatic runtime adapters.
