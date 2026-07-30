---
date: 2026-07-29
area: refactor-patrol, migration, packaging
---

# Product-wide install-time JobStore v3 activation

- Made the shipped package-candidate boundary profile-scoped: each distinct
  `HIVE_HOME` sweeps its complete registered-project catalog, and one user's
  completion status cannot suppress another user's migration.
- Package hooks cover the invoking user immediately. Shared root-owned packages
  use the privileged install-wide coordinator; normal CLI startup never
  converts released-v2 state.
- Added subprocess proof with two independent user installations and two
  released-v2 projects per user, including custom state roots. Invoking one
  explicit profile migration converts both projects in that user's registry.
- Documented the v2 tombstone/sealed-source plus v3 authority layout and the
  exact operator restore command that quarantines the complete v3 generation.
