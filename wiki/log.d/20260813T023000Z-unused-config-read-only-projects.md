---
date: 2026-08-13
slug: unused-config-read-only-projects
pages: [modules/config]
---

Removed the orphaned `Hive::Config.registered_projects_read_only` projection
and its isolated test. The status-report path that required a non-migrating
legacy registry observation was retired; active registry consumers continue to
use `registered_projects`. The unreachable non-migrating registry-path branch
was removed with the facade, so the retained reader always performs the normal
one-off legacy migration. Updated [[modules/config]] accordingly.
