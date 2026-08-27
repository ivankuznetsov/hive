---
date: 2026-08-26
title: Bound managed Git network operations
tags: [git, publication, patrol, timeout, credentials]
---

- Added a shared 60-second deadline to managed remote observation, fetch, and
  exact publication, including process-group cleanup for credential helpers
  that retain inherited output pipes.
- Added `HIVE_GH_BIN` as a fail-closed absolute executable override so managed
  services can bypass mutable interactive shell wrappers while preserving
  normal `PATH` lookup when no override is configured.
- Preserved expected-OID publication semantics: a timed-out push is followed by
  the existing independent remote observation before Hive decides whether the
  immutable commit was published.
