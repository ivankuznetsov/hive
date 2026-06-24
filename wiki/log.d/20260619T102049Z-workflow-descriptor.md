---
date: 2026-06-19
slug: workflow-descriptor
pages: [modules/workflows, modules/stages, modules/task]
---

Introduced the coding workflow descriptor as the source of truth behind the
legacy stage and verb constants. `Hive::Workflow` now models immutable
workflow, stage, and advance-verb values; `Hive::Workflows::Coding::DESCRIPTOR`
declares the current nine-stage coding pipeline; and
`Hive::Workflows::Registry.default` resolves the implicit coding workflow.

`Hive::Stages::DIRS`, `Hive::Task::STAGE_NAMES`,
`Hive::Task::STATE_FILES`, and `Hive::Workflows::VERBS` are now derived from
that descriptor at load time while retaining the exact previous values,
ordering, frozen-ness, and `VERBS` hash shapes. Updated [[modules/workflows]],
[[modules/stages]], and [[modules/task]] to document the descriptor-backed
constant source.

Verified with `bundle exec rake test`, `bundle exec rake coverage` (100.00%
line coverage), and `bundle exec rubocop`.
