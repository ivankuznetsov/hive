---
date: 2026-07-25
summary: Add the closed pure project model-routing domain
---

- Added one immutable registry for every public built-in model-routing key and
  family parent. The removed in-process PR digest is intentionally outside the
  registry and `models:` exists only in project config.
- Added strict project `models:` parsing while preserving field absence and
  the unchanged shape of configs with no routing section.
- Added independent exact/coarse/current/legacy field resolution with
  provenance and provider pass-through.
- Added pure reachability filtering so disabled calls and shadowed coarse
  controls do not trigger later profile capability checks.
