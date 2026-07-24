---
date: 2026-07-25
summary: Add the closed pure model-routing domain and config ownership boundary
---

- Added one immutable registry for every public built-in model-routing key,
  family parent, and project/global-digest config owner.
- Added strict project and global-digest `models:` parsing while preserving
  field absence and the unchanged shape of configs with no routing section.
- Added independent exact/coarse/current/legacy field resolution with
  provenance and provider pass-through.
- Added pure reachability filtering so disabled calls and shadowed coarse
  controls do not trigger later profile capability checks.
