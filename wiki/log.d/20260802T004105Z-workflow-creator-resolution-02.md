---
title: Close workflow creator archive and identity gaps
type: fix
created: 2026-08-02
tags: [openclaw, workflow-creator, release-candidate, archive, coverage]
---

- Made candidate gateway and authored/executed instruction bindings compare
  canonical JSON values, preserving integer-versus-float identity instead of
  relying on Ruby numeric equality.
- Required the supported creator facade to resolve exactly one
  `hive-cli-*.gem` release record before binding the installed package.
- Closed the source-archive semantic gap exposed by POSIX PAX `path=` headers:
  per-entry rewrite metadata and unsupported entry types now fail closed, while
  the one Git global `comment=<candidate SHA>` header is accepted exactly.
- Bounded source verification by compressed bytes, entry count, expanded
  bytes, and protected-member bytes before retaining any builder input.
- Added adversarial PAX/extraction, wrong-global-comment, resource-ceiling,
  ambiguous-package, and numeric-type regressions.
- Isolated the component admission-budget subprocess from coverage-injected
  `RUBYOPT`, preventing a second `Coverage.start` during the hosted gate.
