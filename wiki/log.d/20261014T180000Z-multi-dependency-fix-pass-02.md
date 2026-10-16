---
title: Close dependency cycle and base-mode review gaps
date: 2026-10-14
---

- Dependency graph traversal now continues through unreachable gates so a
  resolvable cycle still outranks the gate error during creation and admission.
- Qualified self-reference paths preserve the actual upstream task identity in
  creation errors.
- Status projections and admission fingerprints now pass the configured default
  branch into shared base selection, matching execution when a prerequisite slug
  collides with that branch name.
