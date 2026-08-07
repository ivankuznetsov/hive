---
title: Honor runtime HIVE_BIN in daemon status probes
module: daemon
tags: [status, web, services, binary-drift]
---

Managed Hive web prepends its private gem bin directory to `PATH`. That
directory can contain a second `hive` wrapper, so PATH-only expected-binary
resolution made the web dashboard report false daemon path drift even while
`hive daemon status --json` was healthy. `Hive::Daemon::StatusReport` now
passes the explicit runtime `HIVE_BIN` to the service probe and falls back to
PATH only when the variable is absent.
