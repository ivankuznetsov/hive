---
title: Markers resolves targets through Hive::TaskResolver
type: log
created: 2026-08-16
tags: [markers, task-resolver, refactor]
---

## Summary

`hive markers clear` no longer carries its own copy of the command-side
task resolution. `Commands::Markers#resolve_task` now delegates to
`Hive::TaskResolver`, deleting the private `resolve_target`,
`path_target?`, `project_hint`, `ambiguity_message`,
`find_slug_across_projects`, and `validate_project_path_match!`
duplicates (which self-described as "mirrors Hive::Commands::Approve").

## Why it matters

- One resolution rule set: path validation, slug/numeric-id lookup,
  ambiguity candidates, realpath, and `--project` mismatch checks stay
  defined once in [[modules/task_resolver]].
- Workflow-aware slug scans: the deleted copy walked the legacy
  coding-only `Hive::Stages::DIRS` list, so a slug living in a
  runtime-registered workflow stage raised "no task folder for slug".
  The resolver walks each project's registered workflow stage union via
  `Hive::Workflows.stages_for_project`, matching the documented
  architecture ([[modules/workflows]]).

## Behavior deltas

- Numeric task ids are now accepted by `hive markers clear` (resolver
  capability the duplicated code lacked).
- The `--project` path-mismatch error says "TARGET path is in project…"
  instead of "FOLDER path is in project…" (shared resolver wording).

## Coverage

`test/integration/markers_command_test.rb` pins the positive path with
`test_clear_by_slug_resolves_task_in_runtime_registered_workflow_stage`
(a dispatch-fixture task in `2-gather`) and asserts the resolver's
mismatch message.
