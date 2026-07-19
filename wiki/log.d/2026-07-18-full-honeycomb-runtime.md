---
date: 2026-07-18
slug: full-honeycomb-runtime
---

- Added immutable digest-addressed managed-workflow configuration snapshots,
  lock schema v2, task configuration pins, in-memory agent/model/effort overlay,
  profile-drift checks, and retention across update/removal. Unsupported
  non-null pins now fail during snapshot construction, unsupported defaults
  remain nil, and managed council children use only their own mapped identity
  instead of inheriting parent-stage model/effort values across providers.
- Changed managed execution to enforce each stage/reviewer/reviser permission
  descriptor instead of reconstructing policy from the catalog union. Explicit
  unbounded actors require separate escalation consent.
- Added strict `x-hive` tool/input validation, Git executable-mode preservation,
  immutable package-root prompt context, and per-slot optional-input isolation.
- Bumped workflow install/update JSON contracts to v2 with mappings,
  configuration identity, policy fingerprints, and redacted input state.
