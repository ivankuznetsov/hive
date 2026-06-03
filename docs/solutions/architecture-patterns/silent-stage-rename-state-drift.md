---
title: Silent stage rename state drift
date: 2026-05-26
category: architecture-patterns
module: Hive::Stages
problem_type: architecture_pattern
component: development_workflow
severity: high
applies_when:
  - "Renaming a filesystem-backed state bucket such as a Hive stage directory"
  - "Migrating long-lived projects where old on-disk state can survive after code constants change"
  - "Adding producer output that only scans the new canonical state locations"
tags:
  - stages
  - migration
  - status
  - filesystem-state
  - regression-guard
  - state-drift
---

# Silent stage rename state drift

## Context

Hive's workflow state lives on disk. `Hive::Stages::DIRS` is the canonical code-side stage list, but task folders can remain under older stage directory names long after a rename ships. PR #78 introduced the PR-first layout and the `hive migrate` command; PR #93 later found that `Status#collect_rows` only walked the new `Stages::DIRS`, so tasks left in legacy directories such as `5-review`, `6-pr`, or `7-done` disappeared from `hive status`, the TUI, and downstream consumers until an operator manually noticed and ran `hive migrate`.

The regression class is broader than those exact stage names: whenever a code constant names durable state buckets, renaming the constant without a migration and a producer-side visibility check creates code-vs-disk drift. The data still exists, but the current code stops looking at it.

## Guidance

Treat a stage rename as a three-part migration contract, not a one-file constant edit.

### 1. Map every legacy bucket directly to the current canonical bucket

`Hive::Commands::Migrate::STAGE_RENAMES` should point from every known legacy stage directory to the current `Hive::Stages::DIRS` name in one hop. Do not chain old names through intermediate layouts; dormant projects should migrate correctly even if they skipped several releases.

```ruby
STAGE_RENAMES = {
  "5-review" => "6-review",
  "6-pr" => "8-finalize",
  "7-done" => "9-done",
  "7-finalize" => "8-finalize",
  "8-done" => "9-done"
}.freeze
```

Keep the task-folder predicate shared. `Hive::Stages.task_slug?` is used both by migration and status detection, so the warning count matches what `hive migrate` is allowed to move.

### 2. Surface unknown-but-non-empty buckets from producers

Any producer that enumerates canonical buckets should also scan for non-canonical siblings that still contain task-shaped state. For Hive status, the detector walks `<hive_state>/stages/`, skips current `Stages::DIRS`, counts slug-shaped task subfolders, and emits structured recovery data:

```ruby
legacy_stage_dirs = detect_legacy_stage_dirs(hive_state)
out["legacy_stage_dirs"] = legacy_stage_dirs
out["legacy_migrate_command"] = legacy_stage_dirs.empty? ? nil : "hive migrate"
```

The text path mirrors the JSON with an operator-readable warning naming the hidden stage directories and the recovery command. This turns invisible state loss into a visible, actionable migration prompt.

### 3. Pin both the code relationship and the producer behavior

Use a pair of regression tests because they protect different failure modes:

- A pure unit test for cross-file consistency, e.g. every `Migrate::STAGE_RENAMES` value must be present in `Hive::Stages::DIRS`, no legacy key may still be canonical, and no key may also be a target.
- An integration test that seeds a legacy stage directory with task folders and asserts the producer surfaces the warning/JSON fields while clean projects produce an empty array and no recovery command.

The first test catches a bad constant change before I/O is involved. The second catches a future refactor that removes or weakens the visibility warning even though the migration map still exists.

## Why This Matters

Filesystem-backed workflows preserve state precisely so an operator or agent can recover from code changes, crashes, and partial runs. A silent rename bug breaks that promise: tasks are not deleted, but every current surface acts as if they do not exist.

The fix is intentionally redundant. Migration moves the state; status warns when migration has not happened yet; tests keep the migration map and the warning path aligned with the canonical stage list. That combination makes future stage-layout work fail loudly instead of depending on an operator noticing missing rows days later.

## When to Apply

- A durable directory, table, enum value, marker name, queue name, or config key is renamed.
- Current code enumerates only the new canonical names but old state may still be present.
- A migration command exists, but producers can still run before the migration is applied.
- The user-facing symptom would otherwise be absence: missing rows, missing tasks, empty dashboards, or skipped work.

## Examples

Before: a producer only iterates the current stage list.

```ruby
Hive::Stages::DIRS.each do |stage_dir|
  collect_rows_for(stage_dir)
end
```

After: the producer still uses the canonical list for normal rows, but it also emits a separate legacy-state signal for non-canonical directories that contain task folders.

```ruby
rows = collect_rows(hive_state)
legacy = detect_legacy_stage_dirs(hive_state)
payload = {
  "tasks" => rows.map { |row| task_payload(row) },
  "legacy_stage_dirs" => legacy,
  "legacy_migrate_command" => legacy.empty? ? nil : "hive migrate"
}
```

## Related

- GitHub issue #97 - requested this durable capture after repeated stage-rename drift bugs.
- PR #78 - introduced the PR-first stage layout and `hive migrate`.
- PR #93 - added `Status#detect_legacy_stage_dirs` and the consistency/integration test pair.
- `wiki/decisions.md` ADR-024 - records the PR-first workflow and stage renumbering decision that made the migration contract necessary.
- `wiki/modules/stages.md` - documents `Hive::Stages::DIRS` as the canonical stage list.
- `wiki/commands/status.md` and `wiki/commands/migrate.md` - document the producer warning and recovery command surfaces.
