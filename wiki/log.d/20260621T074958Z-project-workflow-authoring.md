---
date: 2026-06-21
slug: project-workflow-authoring
pages: [modules/workflows, commands/workflow, cli, testing]
---

Added project-authored workflow discovery and authoring. User descriptors now
live under `<hive_state_path>/workflows/*.yml`, parse through
`Hive::Workflows::DescriptorParser`, and register through a project overlay in
`Hive::Workflows::Registry` so `hive new --workflow`, `hive init --workflow`,
status scans, `hive run`, `hive approve`, and daemon-dispatched commands see
the active project's workflows.

Agent stages may carry either `skill:` or an owner-authored `instruction:`
file, and may include descriptor-level `permissions:` validated with
`Hive::PermissionScope`. Added `hive workflow new ID` to scaffold a blank
`inbox -> work -> done` workflow plus placeholder `work.md` instruction under
the state tree.

Updated [[modules/workflows]], [[commands/workflow]], [[cli]], and
[[testing]] with the new descriptor, command, and acceptance-test coverage.
