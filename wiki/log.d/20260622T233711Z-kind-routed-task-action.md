---
date: 2026-06-22
slug: kind-routed-task-action
pages: [modules/task_action, modules/workflows]
---

Retired the production `TaskAction` coding stage-name case. Coding status
classification now routes through descriptor `kind:` values: execute,
review-council, and finalize use their runtime helpers directly, while coding
agent/inert stages read `Hive::Workflows::Coding::ACTION_DISPATCH` for the
stage-specific user-facing action keys that generic workflows do not share.

Relabeled the coding descriptor's execute, open-pr, review, artifacts, and
finalize stages away from the legacy `:marker` kind and removed `:marker` from
`Hive::Workflow::KNOWN_KINDS`. A test-only parity harness keeps comparing the
retired case table against the production kind path across coding markers,
diagnostics, and command strings.
