---
title: Remove unused TUI subprocess placeholder
date: 2026-08-13
---

- Removed the uncalled `Hive::Tui::SubprocessRegistry.register_placeholder`
  sentinel path left behind after foreground signal forwarding was retired.
- Retained empty-registry no-op behavior, real process-group termination, slot
  clearing, and proof that quiet subprocesses do not mutate the registry.
