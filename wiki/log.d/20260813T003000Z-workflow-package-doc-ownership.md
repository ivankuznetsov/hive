---
title: Give managed workflow packages one documentation owner
created: 2026-08-13T00:30:00Z
tags: [wiki, workflow-package, honeycomb, permissions, architecture]
---

- Added [[modules/workflow_package]] as the authoritative page for managed
  Honeycomb trust, storage, mappings, runtime policy, consent, and publication.
- Returned [[modules/workflows]] to descriptor, registry, verb, and runner
  ownership; its source frontmatter no longer claims `lib/hive/workflow_package/`.
- Reduced [[commands/workflow]], `docs/workflows.md`, and `docs/permissions.md`
  to their command and user-facing contracts with links to the authoritative
  policy page.
- Moved the 2026-07-19 flagship release proof out of the evergreen command
  reference and into its dated log fragment.
- Returned `TaskAction::READY_COMMANDS` dispatch documentation to the
  task-action module page so the package owner stays package-specific.
