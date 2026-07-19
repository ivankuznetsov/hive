---
date: 2026-07-19
slug: managed-store-residual-hardening
---

- Made invalid managed selections observable without sacrificing sibling
  isolation: missing, malformed, and digest-tampered configuration snapshots
  each produce one workflow-named warning while healthy selections still load.
- Made generation cleanup fail closed when a task declares any managed
  provenance value without the complete workflow/source-commit/manifest-digest
  tuple. Legacy task pins may still omit only the configuration digest.
- Hardened generation directories and payload files before same-parent atomic
  publication, retained trusted executable payloads, and repaired exact modes
  when an already validated generation is reused.
