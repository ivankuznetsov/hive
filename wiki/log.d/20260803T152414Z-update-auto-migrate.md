---
date: 2026-08-03
title: Update now migrates registered projects automatically
tags: [update, migration, cli]
---

- `hive update` now waits for its detected channel updater, resolves the newly
  installed Hive executable, and runs `hive migrate --all` automatically.
- Added `hive migrate --all` with global-state and per-project progress,
  continue-after-project-failure behavior, final counts, readable errors, and
  exact recovery commands.
- `hive update --dry-run` now previews both the channel update and the
  post-update migration without executing either phase.
- Update notices now recommend `hive update` on brew, AUR, and bash so guided
  upgrades cannot bypass the automatic migration phase.
- Recovery commands preserve the active `hive` or `hv` wrapper, stale registry
  rows receive restore/forget/prune guidance, and daemon restart requests are
  coalesced until the full fleet pass finishes.
