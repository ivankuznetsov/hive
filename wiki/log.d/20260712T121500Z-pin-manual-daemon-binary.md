---
title: Pin manual daemon children to the invoked Hive binary
date: 2026-07-12
---

- `hive daemon start` now fills an absent `HIVE_BIN` from the invoked
  `hive`/`hv` executable after daemonization. Manual foreground and detached
  daemons therefore dispatch the same checkout or package that launched them
  instead of silently resolving an older `hive` from `PATH`.
- Explicit `HIVE_BIN` values from systemd/launchd units or operators remain
  authoritative.
- Added command tests for both inferred and explicit runtime binary selection.
