---
title: Remove unused managed permission-scope facade
date: 2026-08-13
---

- Removed the uncalled `Hive::PermissionScope.resolve_managed` convenience
  entrypoint. Managed workflow compilation already uses
  `resolve_managed_spec`, which returns both the normalized scope and parsed
  permission declaration required by its runtime policy.
- Retained direct coverage that managed scope resolution bypasses the legacy
  Claude-only gate while preserving the parsed declaration.
