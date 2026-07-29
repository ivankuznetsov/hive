---
date: 2026-07-29
area: refactor-patrol, migration, packaging
---

# Product-wide per-user JobStore v3 activation

- Made the shipped first-use boundary installation-scoped for every Hive user:
  each distinct `HIVE_HOME` sweeps its complete registered-project catalog, and
  one user's completion status cannot suppress another user's migration.
- Package hooks cover the invoking user immediately; shared-package users are
  covered by the same gate on their first eligible CLI invocation. AUR does
  not root-scan unrelated home directories.
- Added subprocess proof with two independent user installations and two
  released-v2 projects per user, including custom state roots. Invoking one
  project command converts both projects in that user's registry.
- Documented the v2 tombstone/sealed-source plus v3 authority layout and the
  exact operator restore command that quarantines the complete v3 generation.
