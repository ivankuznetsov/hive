---
title: hive migrate
type: command
source: lib/hive/commands/migrate.rb, lib/hive/stages.rb
created: 2026-05-21
updated: 2026-06-05
tags: [command, migration, stages, task-id, display-name]
---

**TLDR**: `hive migrate [PROJECT_PATH]` is the explicit, idempotent upgrade path for tasks and config keys created before the PR-first layout, later 7-artifacts insertion, and task-id/display-name sidecar additions.

## Usage

```bash
hive migrate [PROJECT_PATH]
```

`PROJECT_PATH` defaults to the current directory. The command requires `<project>/.hive-state/stages/` to exist.

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

For one compatibility window, `Stages::Finalize` reads legacy `budget_usd.pr` / `timeout_sec.pr` as fallbacks. `hive migrate` rewrites those keys to `budget_usd.finalize` / `timeout_sec.finalize`; canonical keys win when both are present.

## Task metadata backfill

After any stage-directory movement, or on an otherwise no-op migrated project, `hive migrate` scans `<project>/.hive-state/stages/*/<slug>/` and writes missing/null `<task>/meta.yml` ids via `Hive::TaskMeta` and `Hive::TaskCounter`.

- Existing numeric ids are skipped and never reassigned.
- Existing display names are preserved when a null-id sidecar is repaired.
- The global counter is first seeded above the maximum existing id in the scanned project, so cloned or partially migrated state continues from the highest committed sidecar id instead of restarting at 1.
- Backfill order is deterministic: tasks sort by `idea.md` frontmatter `created_at`, then slug; tasks with no parseable `created_at` sort last by slug.

After the locked id/config/stage migration finishes, `hive migrate` also backfills missing/null `display_name` values for every canonical task folder using `Hive::DisplayName::Generator`, the same agent-backed pipeline as `hive generate-name <target>`. Generation runs outside the commit lock because agent naming can take seconds per task; successful names are committed in a separate `.hive-state` commit. Existing display names are skipped, including patrol handoff names such as `Patrol: <finding title>`. A generation failure is fail-soft: that task keeps its null display name and can be retried by rerunning `hive migrate` or `hive generate-name`.

## Commit behavior

All changes run under the project commit lock. The command stages and commits changes inside `.hive-state` only when there is a diff:

- `hive: migrate stage directories (N tasks)` for task moves.
- `hive: migrate config keys (no tasks moved)` for config-only rewrites.
- `hive: migrate task ids (N tasks)` for id-only backfills.
- `hive: migrate display names (N tasks)` for display-name-only backfills.

A rerun after successful migration prints that there is nothing to move and keeps the current stage directories in place.

## Tests

- `test/unit/commands/migrate_renames_consistency_test.rb` pins the stage rename map against `Hive::Stages::DIRS`.
- `test/integration/migrate_test.rb` covers stage-dir moves, config rewrites, task-id backfill order, display-name backfill, idempotency, null-id repair, and counter seeding.
- Status integration scenarios prove hidden legacy tasks surface before migrate and disappear after migration.

## Backlinks

- [[cli]] · [[commands/status]] · [[stages/index]] · [[state-model]]
