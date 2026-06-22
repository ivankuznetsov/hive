---
date: 2026-06-23
slug: drop-numeric-id
pages: [commands/drop, modules/task_resolver]
---

`hive drop` now treats an all-digits target as a task id and routes it through
`Hive::TaskResolver`, matching the existing `run`/`approve`/`findings` target
semantics. The command still uses its bespoke slug context for bare slugs so the
lock-held active/archive snapshot and cleanup context stay unchanged.

Added integration coverage for successful `drop <id>`, unknown-id JSON errors
using the resolver's `"no task folder for id <id>"` message, and duplicate-id
ambiguity across projects with `--project` disambiguating the selected task.
