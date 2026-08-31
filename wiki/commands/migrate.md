---
title: hive migrate
type: command
source: lib/hive/commands/migrate.rb, lib/hive/commands/migrate_all.rb, lib/hive/runtime_control_plane/activation_gate.rb, lib/hive/runtime_control_plane/cutover.rb, lib/hive/patrol_fix/admission_store.rb, lib/hive/workflow_package/task_migrator.rb, lib/hive/stages.rb
created: 2026-05-21
updated: 2026-08-30
tags: [command, migration, config, reviewers, stages, task-id, display-name, recovery, plan-review, update, attempt-storage, patrol]
---

**TLDR**: `hive migrate [PROJECT_PATH]` upgrades one project's Markdown task
authority. `hive migrate --all --yes` is a different, installation-wide
offline operation: it creates one verified SQLite candidate for the complete
included fleet and publishes activation only after every included project validates.

## Usage

```bash
hive migrate [PROJECT_PATH]
hive migrate --all [--yes] [--exclude-project NAME]
```

`PROJECT_PATH` defaults to the current directory. The command requires `<project>/.hive-state/stages/` to exist.

`--all` and `PROJECT_PATH` are mutually exclusive. Fleet mode is irreversible
and requires explicit confirmation. On a TTY it prompts for `yes`; non-TTY use
without the flag fails with the exact `hive migrate --all --yes` action. Missing registered projects must be repaired or named with
`--exclude-project`; exclusions and their reason are durable manifest evidence.
Corrupt reachable projects, live owners, changing task authority, or missing
task ids stop activation. The task-authority fingerprint covers each project's
canonical `stages/` tree; project-local babysitter worktrees are disposable
runtime and are not interpreted as task authority. Regular task files remain
part of the fingerprint when they are hardlinked (for example, tool outputs in
an archived task); symlinks and non-regular entries still fail closed. Project
task files remain byte-identical before the activation-intent manifest.

The package manager publishes the candidate normally; Hive never renames a
package-owned launcher or preserves the previous executable tree. Before any
candidate startup mutation, an early read-only gate refuses ordinary commands.
Cutover journals the exact service state before stopping daemon, bot, and Web,
rejects live owners, snapshots and validates token usage while holding the
legacy database against late writers through fencing, and installs permanent
path-shape tombstones over retired writer paths. It rebuilds project and task
identity from file authority, validates the complete SQLite candidate before
any tombstone, resets the remaining machine-local runtime domains, records
irreversible intent, activates the database authority, and then restarts only
services that were running. Task journals, projections, artifacts, and referenced
payload files remain untouched. An interruption after fencing leaves evidence
and tombstones in place; `hive runtime resume` only converges forward. Normal
runtime never creates or migrates the database and has no legacy fallback.

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

The Patrol-policy cutover removes only the retired mapping entry and its value.
Blank lines and comments that follow it remain attached to the next surviving
key or section. The rewrite is committed independently before current config
loading; a single-project migration requests its best-effort daemon restart at
that point, so a later project-specific migration failure cannot leave a live
daemon on the removed policy.

`hive update --yes` lets the configured package manager publish the candidate
normally, then runs that candidate's confirmed fleet cutover. The previous
release's existing update route invokes candidate `migrate --all` without the
flag; the candidate obtains confirmation interactively or refuses non-TTY use
with the exact explicit rerun instruction.
The single-project command remains the explicit preparation path for missing
task identities; the fleet command never invents DB-only ids or commits task
files before activation intent.

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

The same locked pass stamps `plan_review_required: true` on every built-in
coding task still in stages 1–3. New coding tasks receive the bit at creation.
Tasks already at `4-execute` or later are deliberately not stamped, allowing
the execute-entry guard to issue the explicit pre-feature adoption receipt
without retroactively stranding work. This durable distinction prevents a
post-feature task from deleting its task-local review root and using a raw
folder move as a legacy bypass. Non-coding workflows are untouched.

After the locked id/config/stage migration finishes, `hive migrate` also backfills missing/null `display_name` values for every canonical task folder using `Hive::DisplayName::Generator`, the same agent-backed pipeline as `hive generate-name <target>`. Generation runs outside the commit lock because agent naming can take seconds per task; successful names are committed in a separate `.hive-state` commit. Existing display names are skipped, including patrol handoff names such as `Patrol: <finding title>`. A generation failure is fail-soft: that task keeps its null display name and can be retried by rerunning `hive migrate` or `hive generate-name`.

The same explicit command backfills missing `completed_at` values for tasks
already classified as archived. It prefers the earliest credible Git completion
event, then the terminal state-file mtime, then the task-folder mtime, and
commits successful discoveries as `hive: migrate completion times (N tasks)`.
History discovery runs before the project commit lock. The locked write phase
re-resolves every candidate and persists only tasks that are still archived and
unstamped, then stages and commits only their exact `meta.yml` paths. A failed
commit restores the original metadata and exits non-zero, so rerunning
`hive migrate` can complete the same repair. One malformed task warns and stays
visible while valid candidates still commit. Missing sources likewise warn and
leave the task visible. The daemon, status command, `approve`, and `run` do not
perform legacy metadata discovery or migration.

## Patrol Fix admission index cutover

`hive migrate` scans an existing project-local Patrol Fix admission inventory
once and writes its compact pending index. The index contains occurrence ids
and their immediate or time-based eligibility only; full admission records
remain authoritative. A successful rebuild reports the indexed and total
record counts and is byte-idempotent on a rerun. If an old daemon is running,
the command synchronously restarts it and performs one final index pass. That
second pass closes the finite window in which the old process could have
written without maintaining the new index. If Hive cannot replace a running
daemon automatically, migration fails with exact stop, rerun, and start
commands. Projects without an admission inventory are not materialized. This
index rewrite belongs only to the explicit single-project command; fleet
cutover observes project authority and never runs project-local mutators before
activation intent.

Runtime `AdmissionStore#pending` reads the index once and opens at most twice
its requested record limit when repairing crash residue; a clean tick opens
only the records it returns. Inventory-lock contention skips one scheduler tick
instead of stalling the daemon. An existing record inventory with a missing or
invalid index fails closed with a `hive migrate` remediation instead of
rebuilding during a daemon tick. There is no periodic migration, full-scan
repair watcher, or compatibility reader. Normal writers maintain the
projection, and bounded read-time repair corrects only selected stale entries
after an interrupted record/index transition.

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

## Runtime activation surface

The attempts-v4 recovery state machine and `Hive::Recovery::Migration` facade
are deleted. `Hive::RuntimeControlPlane::Cutover` is the explicit fleet
cutover/bootstrap/resume composition boundary. It has no general legacy decoder:
the only retained-history adapter validates and imports the legacy token-usage
SQLite database. `hive runtime status|resume` is the entire maintenance surface.
Status validates the immutable manifest and exact database identity; resume
revalidates task authority and the token-usage snapshot before moving forward.
Hive deliberately provides no runtime backup, restore, rollback, or downgrade
branch for this one-way transition.

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

Recovery-marker backfill resolves a pinned managed task's state file directly
from its descriptor while the workflow mutation lock is held. Unpinned tasks
use an immutable workflow generation captured before that lock. Neither path
performs live workflow loading inside the transaction, because that would
reacquire the same non-reentrant lock and deadlock an update.

The cutover is idempotent. Updating one or more pins restarts a running daemon
so its managed-workflow cache observes the new selection immediately.

## Commit behavior

All changes run under the project commit lock. The command stages and commits changes inside `.hive-state` only when there is a diff:

- `hive: migrate stage directories (N tasks)` for task moves.
- `hive: migrate config keys (no tasks moved)` for config-only rewrites.
- `hive: migrate task ids (N tasks)` for id-only backfills.
- `hive: migrate recovery markers (N tasks)` for recovery-only identity backfills.
- `hive: migrate managed workflow tasks (N tasks)` for a managed-generation-only cutover.
- `hive: migrate plan review requirements (N tasks)` for a plan-review-requirement-only cutover.
- `hive: migrate project state (N ids, M recovery markers, P managed workflow tasks, Q plan review requirements)` when multiple non-stage upgrades land together; zero-value categories are omitted.
- `hive: migrate completion times (N tasks)` for archived completion-clock backfills.
- `hive: migrate display names (N tasks)` for display-name-only backfills.

A rerun after successful migration prints that there is nothing to move and keeps the current stage directories in place.

## Tests

- `test/unit/commands/migrate_renames_consistency_test.rb` pins the stage rename map against `Hive::Stages::DIRS`.
- `test/unit/commands/migrate_all_test.rb` covers the thin fleet-cutover
  delegation, TTY and non-TTY confirmation, and exclusions.
- `test/integration/migrate_test.rb` covers stage-dir moves, the legacy
  reviewers relocation/conflict boundary, other config rewrites, task-id
  backfill order, plan-review requirement/adoption boundary, display-name
  backfill, `ERROR` / `REVIEW_ERROR` identity
  backfill, managed semantic-stage generation/configuration migration,
  repository-identity backfill, idempotency, null-id repair, and
  counter seeding.
- `test/unit/patrol_fix/admission_store_test.rb` and
  `test/integration/migrate_test.rb` cover bounded pending-record reads,
  explicit index construction, stale selected-entry repair, idempotency, and
  the daemon restart request.
- `test/unit/workflow_package/task_migrator_test.rb` covers semantic stage
  moves, same-position repins, removed-stage refusal, lock contention, cleanup,
  and idempotency.
- `test/unit/runtime_control_plane/cutover_test.rb` covers fleet atomicity,
  live-owner refusal, disposable runtime reset, exact-once token-usage import,
  permanent path-shape fences, and crash-forward resume.
- `test/unit/runtime_control_plane/activation_gate_test.rb` proves inactive
  ordinary commands fail before wiki reconciliation while maintenance routes
  remain available.
- Status integration scenarios prove hidden legacy tasks surface before migrate and disappear after migration.

## Backlinks

- [[cli]] · [[commands/status]] · [[stages/index]] · [[state-model]] · [[modules/plan_review]]
