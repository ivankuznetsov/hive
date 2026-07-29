---
title: hive migrate
type: command
source: lib/hive/commands/migrate.rb, lib/hive/stages.rb
created: 2026-05-21
updated: 2026-07-29
tags: [command, migration, config, reviewers, stages, task-id, display-name, recovery]
---

**TLDR**: `hive migrate [PROJECT_PATH]` is the explicit, idempotent upgrade
path for legacy project config, tasks created before the PR-first layout and
later 7-artifacts insertion, task-id/display-name sidecar additions, managed
workflow configuration pins, and the one-off recovery-state and
recovery-marker identity cutovers.

## Usage

```bash
hive migrate [PROJECT_PATH]
```

`PROJECT_PATH` defaults to the current directory. The command requires `<project>/.hive-state/stages/` to exist.

Before project-local changes, the command runs the owner-private recovery-state
cutover for the current Hive state home. Daemon and bot startup run the same
cutover before opening their stores or queues. A foreground default attempt
store fails closed while `attempts/v1` remains, so an upgrade cannot silently
bypass migration or create competing v2 ownership.

## Task-folder renames

`Hive::Commands::Migrate::STAGE_RENAMES` maps the pre-open-pr stage layout onto the current `Hive::Stages::DIRS` list:

| Old stage | New stage |
|-----------|-----------|
| `5-review` | `6-review` |
| `6-pr` | `8-finalize` |
| `7-done` | `9-done` |
| `7-finalize` | `8-finalize` |
| `8-done` | `9-done` |

Only directory entries matching `Hive::Stages.task_slug?` are moved. Stray `.gitkeep`, `.DS_Store`, `logs/`, and other non-task siblings stay in place. The same slug predicate is used by [[commands/status]] to count `legacy_stage_dirs`, so status warnings match what migrate would actually move.

Before moving anything, migrate preflights every destination and raises `Hive::DestinationCollision` if any target already exists. That prevents partial filesystem migration when one slug collides mid-loop.

## Config-key rewrite

For one compatibility window, `Config.load` treats a root-level `reviewers`
value as `review.reviewers` and warns instead of making an upgraded project
unusable. `hive migrate` moves the complete YAML block under `review`, retains
its comments, and removes the root key. If both locations are present, the
command fails before writing and asks the operator to choose which value to
keep. Generated Hive configs use a block-form `review:` mapping; a hand-written
flow mapping must be converted manually before the comment-preserving rewrite
can run.

`hive update` replaces the installed CLI through its package channel and does
not mutate or commit registered projects' tracked task/config state. The
compatibility alias is what makes that binary update safe; run `hive migrate`
in each warned project to persist the correction.

Architecture Patrol's installation-managed JobStore cutover is different: it
is an automatic shipped installation migration over untracked runtime state. A
candidate generation sweeps the installation's complete current registry
before any Architecture Patrol runtime restart. Hive installations and
registries are user-scoped, so the shipped binary repeats this boundary for
every user: the package hook covers the installing user immediately, and each
other user's first eligible Hive invocation sweeps that user's entire
registered-project catalog. One user's completion receipt never suppresses a
different user's sweep because each lives under that user's `HIVE_HOME`.

Each sweep attempts every registry row without filtering on the project
directory's Unix owner, including shared projects created or owned by another
user and relative or absolute custom `hive_state_path` values. The invoking
process still cannot exceed its operating-system permissions; an inaccessible
project becomes a persisted failed/retryable row instead of being silently
skipped. Package managers running as root do not crawl arbitrary home
directories: Homebrew and `install.sh` run the candidate command for the
invoking user, while AUR tells every user that first use is the activation
boundary. `status`, `watch`, `doctor`, findings inspection, dry runs, and other
strict observation routes remain mutation-free; a daemon start or the next
eligible mutating command performs the sweep.

A newly registered or path-drifted project changes the registry digest and
forces a new sweep without waiting for the normal hourly retry. First JobStore
open retains the same one-off converter for otherwise dormant state, but
normal readers accept only v3.

### Candidate installation sweep

```bash
hive refactor-patrol-migrate-installed
```

This is the narrow, candidate-only installation entrypoint used by `hive
update` after a package replacement and before it restarts a daemon it stopped.
It first backfills immutable registry identities with
`Config.ensure_project_identities!`, then runs
`RegisteredProjectMigrationCoordinator` across the complete current registry.
It prints the same typed document persisted at
`$HIVE_HOME/schema-migrations/refactor-patrol-job-v3.json` (`schema:
"hive-installation-job-schema-migration"`, `schema_version: 2`). The document's
registry digest binds the complete user-scoped catalog, so adding or changing a
registration invalidates the prior completion receipt.

A failed or retryable project row still means the sweep itself completed: the
document records its error, remediation, retry time, and custom
`hive_state_path`, while later registered projects continue. Registry,
identity, and status-store failures remain structural command failures. The
command is deliberately not a replacement for user-directed `hive migrate`,
which updates tracked project state.

## Architecture Patrol JobStore cutover and emergency restore

The released aggregate-only JobStore v2 shape is converted directly to v3. No
binding-sidecar compatibility format is recognized. Before the first live job
is replaced, Hive writes and verifies
`<hive_state_path>/refactor_patrol/v3/job-schema-v2-backup/manifest.json` plus
the exact source bytes under `job-schema-v2-backup/jobs/`. The manifest binds
project id, sorted job names, SHA-256, byte size, original mode, and original
mtime into `snapshot-<sha256>`. Each written v3 job is a restart checkpoint;
the completion marker is written only after a final bounded scan finds no v2
job. `hive daemon status --json` exposes that snapshot id and every registered
project's current/target schema, status, retry time, remediation, and error
under `schema_migrations`.

Executable rollback alone is unsafe because the previous package reads only
v2. Emergency state restore is therefore an explicit, fenced operator command,
not a compatibility reader or an automatic downgrade:

```bash
hive daemon stop
hive daemon status --json
hive refactor-patrol-schema-restore PROJECT SNAPSHOT_ID --json
```

Do not run the restore until status proves the daemon stopped and any
separately launched Architecture Patrol worker is also stopped. The command
requires an exact registered-project identity and snapshot id, revalidates the
complete v3 aggregate/conversion ledger, exact v2 backup and sealed source
archive, refuses active claims or changed/new jobs, and stages the exact v2
bytes with their original mode and mtime. It then atomically exchanges that
staged directory with the v2 tombstone and moves the complete v3 generation to
`<hive_state_path>/refactor_patrol/job-schema-restore-quarantine/<transaction-id>/`.
It never deletes the v3 generation or chooses an unverified filesystem path.
Interrupted and repeated restores resume from validated transaction identities.

Only after that command succeeds may an old v2-only package start. On a later
forward upgrade, stop the old daemon again and use the normal installed update
path. The candidate seals the then-current v2 bytes under a fresh transaction,
creates a new v3 generation, and retains the prior quarantine as audit and
recovery evidence.

`Stages::Finalize` likewise reads legacy `budget_usd.pr` /
`timeout_sec.pr` as fallbacks. `hive migrate` rewrites those keys to
`budget_usd.finalize` / `timeout_sec.finalize`; canonical keys win when both are
present.

## Task metadata backfill

After any stage-directory movement, or on an otherwise no-op migrated project, `hive migrate` scans `<project>/.hive-state/stages/*/<slug>/` and writes missing/null `<task>/meta.yml` ids via `Hive::TaskMeta` and `Hive::TaskCounter`.

- Existing numeric ids are skipped and never reassigned.
- Existing display names are preserved when a null-id sidecar is repaired.
- Id repair uses `TaskMeta.update_id`, preserving dependency, base-branch, and
  complete managed workflow provenance rather than reconstructing `meta.yml`.
- The global counter is first seeded above the maximum existing id in the scanned project, so cloned or partially migrated state continues from the highest committed sidecar id instead of restarting at 1.
- Backfill order is deterministic: tasks sort by `idea.md` frontmatter `created_at`, then slug; tasks with no parseable `created_at` sort last by slug.

After the locked id/config/stage migration finishes, `hive migrate` also backfills missing/null `display_name` values for every canonical task folder using `Hive::DisplayName::Generator`, the same agent-backed pipeline as `hive generate-name <target>`. Generation runs outside the commit lock because agent naming can take seconds per task; successful names are committed in a separate `.hive-state` commit. Existing display names are skipped, including patrol handoff names such as `Patrol: <finding title>`. A generation failure is fail-soft: that task keeps its null display name and can be retried by rerunning `hive migrate` or `hive generate-name`.

## Recovery marker identity cutover

Recovery v2 recognizes each durable failure by a random `marker_id`; runtime
code has no mtime/reason fallback. Under the same project commit lock, migrate
resolves each valid task through its workflow descriptor and inspects only that
task's authoritative current state file. Historical artifacts and marker-shaped
examples are not rewritten. If the current marker is `ERROR`, `REVIEW_ERROR`, `REVIEW_STALE`, or
`REVIEW_CI_STALE` and has no identity, migrate rewrites that occurrence with a
generated `marker_id`.

The operation is idempotent: existing identities are preserved, non-recoverable
markers are untouched, and a second run makes no recovery-marker change. An
installed Hive that reports `recovery_migration_required` is asking for this
explicit one-off project migration; automatic recovery stays blocked until it
has run. A task whose workflow descriptor is missing or invalid is left
unchanged because Hive cannot identify its authoritative state file safely;
restore the workflow, then rerun migrate.

## Durable recovery schema cutover

Runtime recovery supports only the current shapes: attempt v3, dispatch request
v4, and dispatch result v2. `Hive::Recovery::Migration` moves
`$HIVE_HOME/attempts/v1` to `attempts/v2`, rewrites v1 generation fields, adds
the explicit task subject required by attempt v3 to v1/v2 records, strips the
obsolete compatibility flag, and migrates pending request v1-v3 and result v1
documents. It writes `recovery-migration-v3.json` only after every active
document is current, then removes the superseded v2 migration receipt.

Final compatibility leases are moved to
`$HIVE_HOME/attempts/legacy-v1-records/` as audit history. A live compatibility
lease, any other live attempt in the old tree, or simultaneous populated
`attempts/v1` and `attempts/v2` trees fails closed with an actionable error. A
pre-cutover reader can recreate only the empty v1 directory skeleton after v2
is authoritative; migrate removes that inert tree with empty-directory-only
`rmdir` operations. Any file, symlink, or concurrent writer preserves the
fail-closed dual-root error. An old detached supervisor retains the explicit v1
path until it terminalizes, so Hive never moves storage underneath live work or
guesses which process owns it. The migration is idempotent; attempt v1/v2
schemas and in-memory compatibility readers are removed after the cutover.

## Registered repository identity backfill

When the current project is already registered but its registry row predates
`repository_identity`, migrate resolves the current `origin`, normalizes it,
and updates that row under the global config lock. An existing identity is
never overwritten. Local origins are intentionally stored as `local:<path>`;
GitHub-only services such as the PR babysitter then skip them without making a
failing `gh` call. If no origin can be resolved, the row remains unresolved and
can be repaired after adding `origin` by rerunning `hive migrate`.

## Managed workflow configuration pin cutover

A managed workflow mapping can change agent, model, effort, or profile
fingerprint without changing the immutable package generation. Existing tasks
on that same source commit and manifest would otherwise remain pinned to an
obsolete execution snapshot and fail closed forever after the old profile
disappears.

`hive migrate` compares each managed task with the currently selected
configuration. When the workflow name, source commit, and manifest digest
match, it validates the selected configuration against the installed package
before changing any task, rewrites only
`workflow_configuration_digest`, and preserves the rest of `meta.yml`.
After every candidate validates, it updates all matching tasks and removes
configuration snapshots that are no longer selected or referenced. Tasks on a
different package generation are intentionally untouched because changing
their descriptor or instructions requires a workflow-specific migration.

The cutover is idempotent. Updating one or more pins restarts a running daemon
so its managed-workflow cache observes the new selection immediately.

## Commit behavior

All changes run under the project commit lock. The command stages and commits changes inside `.hive-state` only when there is a diff:

- `hive: migrate stage directories (N tasks)` for task moves.
- `hive: migrate config keys (no tasks moved)` for config-only rewrites.
- `hive: migrate task ids (N tasks)` for id-only backfills.
- `hive: migrate recovery markers (N tasks)` for recovery-only identity backfills.
- `hive: migrate managed workflow pins (N tasks)` for a configuration-pin-only cutover.
- `hive: migrate project state (N ids, M recovery markers, P managed workflow pins)` when multiple non-stage upgrades land together; zero-value categories are omitted.
- `hive: migrate display names (N tasks)` for display-name-only backfills.

A rerun after successful migration prints that there is nothing to move and keeps the current stage directories in place.

## Tests

- `test/unit/commands/migrate_renames_consistency_test.rb` pins the stage rename map against `Hive::Stages::DIRS`.
- `test/integration/migrate_test.rb` covers stage-dir moves, the legacy
  reviewers relocation/conflict boundary, other config rewrites, task-id
  backfill order, display-name backfill, `ERROR` / `REVIEW_ERROR` identity
  backfill, managed same-generation configuration rebinding and all-candidate
  preflight, repository-identity backfill, idempotency, null-id repair, and
  counter seeding.
- `test/unit/recovery/migration_test.rb` covers the global schema cutover,
  receipt idempotency, archived final compatibility records, queue upgrades,
  empty post-cutover v1 skeleton cleanup, and live/ambiguous-state refusal.
- Status integration scenarios prove hidden legacy tasks surface before migrate and disappear after migration.
- `test/unit/commands/refactor_patrol_candidate_migration_test.rb` covers the
  installation-wide candidate sweep, identity backfill, typed persisted/printed
  status, isolated retryable failures, released-v2 jobs, and custom state roots.

## Backlinks

- [[cli]] · [[commands/status]] · [[stages/index]] · [[state-model]]
