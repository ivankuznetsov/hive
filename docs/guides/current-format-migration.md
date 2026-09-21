# Move an older Hive installation to the current format

Hive reads and creates only current formats. It does not run historical migrations
on startup or update. `hive migrate` and `hive runtime resume` have been removed.
An existing healthy current runtime database needs no conversion or cutover manifest.
Use `hive runtime status --json` to check it. A fresh installation uses `hive setup`.

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
4. Retain a healthy current SQLite database unchanged. If the database format is
   unsupported, archive the old runtime together with its WAL/SHM after all writers
   stop, and initialize a fresh current runtime with services still stopped.
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
