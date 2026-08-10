---
title: Preserve historical managed workflow stages in status
type: fixed
date: 2026-08-10
---

- Exclude successfully loadable, immutable managed workflow task pins from
  `legacy_stage_dirs` when a package update has renamed their historical stage.
- Keep incomplete, corrupt, or unavailable pins fail-closed in the legacy
  count so the scheduler still blocks genuinely unsafe layouts.
- Prevent valid retained workflow history from blocking dispatch for every
  current task in the same project.
