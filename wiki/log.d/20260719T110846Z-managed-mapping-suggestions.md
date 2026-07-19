---
title: Keep managed workflow mapping defaults runnable
type: fix
date: 2026-07-19
---

- Managed workflow installation now suggests Claude when a project-default
  agent cannot enforce a stage, reviewer, or reviser's non-`yolo` permission
  scope.
- Explicit agent mappings remain unchanged and continue to fail closed during
  runtime admission when the selected runner cannot enforce the actor policy.
- Added regression coverage for both automatic fallback and explicit mapping
  preservation.
- Prepared the `0.6.1` patch release and synchronized the gem lockfiles,
  changelog, and public installer references.
