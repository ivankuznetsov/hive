---
title: One-shot local Patrol finding import
type: log
---

- Added `script/migrate_patrol_findings.rb` for local projects that only need active ordinary Patrol findings converted into `patrol-fix` tasks.
- The importer uses deterministic task idempotency and normal `TaskCapture`; it does not create migration state, inspect PRs, publish remotely, or acknowledge/delete source findings.
