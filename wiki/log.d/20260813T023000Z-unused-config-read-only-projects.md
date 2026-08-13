---
date: 2026-08-13
slug: unused-config-read-only-projects
pages: [modules/config]
---

Removed the orphaned `Hive::Config.registered_projects_read_only` projection
and its isolated test. The status-report path that required a non-migrating
legacy registry observation was retired; active registry consumers continue to
use `registered_projects`. Updated [[modules/config]] accordingly.
