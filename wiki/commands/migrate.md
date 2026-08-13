---
title: hive migrate
type: command
source: lib/hive/commands/migrate.rb, lib/hive/commands/migrate_all.rb, lib/hive/workflow_package/task_migrator.rb, lib/hive/stages.rb
created: 2026-05-21
updated: 2026-08-13
tags: [command, migration, config, reviewers, stages, task-id, display-name, recovery, update, attempt-storage]
---

**TLDR**: `hive migrate [PROJECT_PATH]` is the explicit, idempotent upgrade
path for one project. `hive migrate --all` checks global state and every
registered project; `hive update` runs that fleet form automatically after a
successful package update.

## Usage

```bash
hive migrate [PROJECT_PATH]
hive migrate --all
```

`PROJECT_PATH` defaults to the current directory. The command requires `<project>/.hive-state/stages/` to exist.

`--all` and `PROJECT_PATH` are mutually exclusive. Fleet mode prints a global
state check, one progress row and result per registered project, and a final
success/failure count. It continues after a project failure so one broken
registration does not hide the rest of the migration inventory, then exits
non-zero with a human-readable summary. Every failed project includes a
shell-escaped single-project recovery command using the active `hive` or `hv`
wrapper. If a registered path is missing or no longer contains a Hive project,
the command instead names the restore path plus exact `forget` and `prune`
cleanup commands while keeping the fleet result visibly incomplete.

Before project-local changes, the command runs the owner-private recovery-state
cutover for the current Hive state home. Daemon and bot startup run the same
cutover before opening their stores or queues. A foreground default attempt
store opens only the physical v4 layout after the cutover. Obsolete v1 roots
or competing material v2/v3/v4 roots fail closed, so an upgrade cannot
silently choose or create a second authority.

The v4 cutover verifies daily admission accounting against both bounded hot
records and immutable permanent proofs. Terminal attempts may already have
moved out of the hot window before a migration resumes; their same-day counts
remain authoritative and must not be discarded as stale index entries.

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

After replacing the installed CLI through its package channel, `hive update`
runs the new binary's `hive migrate --all`. That can mutate and commit each
registered project's tracked `.hive-state` exactly as an explicit
single-project migration would. A failed project is named with its error and
`hive migrate PROJECT_PATH` recovery command; successful projects are not
rolled back.

Each single-project migration still requests a daemon restart when it changes
stage layout or managed workflow tasks. Fleet mode coalesces those requests and
restarts once only when every registered project succeeds. A partial fleet
failure leaves the current daemon stopped from adopting the new state until the
operator repairs the failed project and reruns `hive migrate --all`.

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

Runtime recovery supports only the current shapes: attempt v4, dispatch request
v5, and dispatch result v2. `Hive::Recovery::Migration` performs a forward-only
physical cutover from `$HIVE_HOME/attempts/v3` to `attempts/v4` (and accepts a
remaining supported v2 source). It takes the shared recovery lock and every
source writer lock, rejects attempts whose owners may still be active, and
converts definitively crashed attempts to ordinary lost records. Only expired
pre-heartbeat launches and running records with missing/mismatched process
identity qualify for that automatic reconciliation. It validates the complete
source tree, atomically renames it, converts valid schema-v3 hot/proof records to explicit
legacy routing mode, and replaces prior paths with owner-private old-binary
fences. Malformed hot bytes remain exact reservations; a malformed permanent
proof fails the migration.

The durable `.v4-cutover.json` checkpoint advances through `fenced`, `verified`,
and `complete`. Before completion Hive compares the exact source corpus and
scan counts, proves decision-index and capacity parity, and promotes historical
final records into permanent proof. Only then does it write
`recovery-migration-v6.json`, migrate pending request v1-v4 and result v1
documents, and remove superseded recovery receipts.

Runtime opens only v4: there is no dual reader, reverse migration, or hydration
back into v2/v3. An obsolete v1 tree, material competing-root collision, live
writer or possibly active attempt, unsupported attempt schema, unsafe tree entry, changed corpus, or
invalid checkpoint/fence fails closed with the evidence preserved. Re-running
after a completed receipt validates the fences, v4 directory, and complete
checkpoint, then returns the same receipt rather than repeating the cutover.

## Registered repository identity backfill

When the current project is already registered but its registry row predates
`repository_identity`, migrate resolves the current `origin`, normalizes it,
and updates that row under the global config lock. An existing identity is
never overwritten. Local origins are intentionally stored as `local:<path>`;
GitHub-only services such as the PR babysitter then skip them without making a
failing `gh` call. If no origin can be resolved, the row remains unresolved and
can be repaired after adding `origin` by rerunning `hive migrate`.

## Managed workflow generation cutover

A managed workflow release can change its immutable package generation, stage
positions, agent mapping, model, effort, or profile fingerprint. Runtime
dispatch supports only the selected generation and configuration; it never
executes a historical package because a retained task still carries an old
pin.

`hive migrate` compares every managed task with the currently selected package
and configuration. The old descriptor is read only inside this migration
boundary to recover the semantic name of the task's current stage. The task is
then moved to that stage's position in the selected descriptor and its source,
manifest, and configuration pins are rewritten together. This permits stage
insertion and reordering. A selected release that removes or renames a stage
still occupied by a retained task fails closed before task mutation; restore
the stable stage name or archive/reset the task. Destination collisions,
malformed metadata, and live task locks likewise stop the project migration
without partially repinning its managed tasks.

The migration preserves task id, display name, dependency, base branch, and
all non-provenance metadata. It removes pending or claimed recovery dispatches
for each migrated task because their stage/policy snapshot is stale, while
terminal recovery receipts remain evidence. Once every task is current,
unreferenced package generations and configuration snapshots are deleted.
`hive workflow install` and `hive workflow update` run the same migration inside
the selection-activation transaction, so the pointer and retained tasks land in
one state commit; `hive workflow remove` refuses while any retained task still
names the workflow.

The cutover is idempotent. Updating one or more pins restarts a running daemon
so its managed-workflow cache observes the new selection immediately.

## Commit behavior

All changes run under the project commit lock. The command stages and commits changes inside `.hive-state` only when there is a diff:

- `hive: migrate stage directories (N tasks)` for task moves.
- `hive: migrate config keys (no tasks moved)` for config-only rewrites.
- `hive: migrate task ids (N tasks)` for id-only backfills.
- `hive: migrate recovery markers (N tasks)` for recovery-only identity backfills.
- `hive: migrate managed workflow tasks (N tasks)` for a managed-generation-only cutover.
- `hive: migrate project state (N ids, M recovery markers, P managed workflow tasks)` when multiple non-stage upgrades land together; zero-value categories are omitted.
- `hive: migrate display names (N tasks)` for display-name-only backfills.

A rerun after successful migration prints that there is nothing to move and keeps the current stage directories in place.

## Tests

- `test/unit/commands/migrate_renames_consistency_test.rb` pins the stage rename map against `Hive::Stages::DIRS`.
- `test/unit/commands/migrate_all_test.rb` covers global and per-project fleet
  progress, continue-after-failure behavior, human-readable errors, and exact
  recovery commands.
- `test/integration/migrate_test.rb` covers stage-dir moves, the legacy
  reviewers relocation/conflict boundary, other config rewrites, task-id
  backfill order, display-name backfill, `ERROR` / `REVIEW_ERROR` identity
  backfill, managed semantic-stage generation/configuration migration,
  repository-identity backfill, idempotency, null-id repair, and
  counter seeding.
- `test/unit/workflow_package/task_migrator_test.rb` covers semantic stage
  moves, same-position repins, removed-stage refusal, lock contention, cleanup,
  and idempotency.
- `test/unit/recovery/migration_test.rb` covers the physical v2-to-v3 cutover,
  exact parity and crash resume, real finalization obligations, v1 empty-skeleton
  pruning, strict schema rejection, queue upgrades, and live/ambiguous-state
  refusal.
- Status integration scenarios prove hidden legacy tasks surface before migrate and disappear after migration.

## Backlinks

- [[cli]] · [[commands/status]] · [[stages/index]] · [[state-model]]
