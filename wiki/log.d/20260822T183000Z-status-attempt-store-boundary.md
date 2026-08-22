---
title: Status scan is a cataloged attempt-store construction site
date: 2026-08-22
---

- `config/component-boundaries.yml` now authorizes `lib/hive/commands/status.rb`
  to construct `Hive::Attempts::Store`.
- The scan-scoped store hoist in `hive status` calls
  `Hive::Attempts::Store.runtime`, and `runtime` counts as a construction in the
  component-boundary contract, so the catalog needed the new file entry.
- Authorization is unchanged in kind: `TaskProjection::Store` and `TaskClosure`
  were already authorized to open the same read-only store per row; status now
  opens it once per scan instead.
