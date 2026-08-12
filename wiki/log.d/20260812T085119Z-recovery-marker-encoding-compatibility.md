---
title: Recovery accepts byte-identical Unicode marker attrs
type: change
date: 2026-08-12
---

Valid UTF-8 marker attrs now cross the shared `Hive::Recovery` compatibility
boundary before durable request and scheduler-snapshot comparison. This keeps
the marker scanner's binary safety while preventing an encoding-label-only
`generation_conflict` after JSON restores the same bytes as UTF-8.

`RecoveryCoordinator`, `Markers.clear_current`, recovery observation tokens,
and operational scheduler joins share the canonicalization. Focused
regressions cover an em-dash diagnostic round-tripping through the recovery
queue and the same binary/UTF-8 split in operational status.
