---
date: 2026-09-25
title: External scheduler one-shot execution
tags: [daemon, patrol, refactor-patrol, babysitter, scheduling]
---

- Added a shared `hive-one-shot.v1` scheduling report and project ownership
  guard for bounded Patrol, Architecture Patrol, babysitter, and dispatch
  passes. Reports preserve immediate, external, and operator waits and expose
  exact deadlines and wake conditions without introducing a timer service.
- `hive babysit --once`, including an empty `--all`, now emits the shared JSON
  envelope by default. A daemon-owned babysitter one-shot refuses with
  `daemon_owned` and exit 75, while the normal long-lived daemon and babysitter
  services continue to coexist.
