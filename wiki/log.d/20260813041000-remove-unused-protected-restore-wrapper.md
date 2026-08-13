---
title: Remove unused protected-file restore wrapper
date: 2026-08-13
---

- Removed the uncalled `Hive::ProtectedFiles.restore_safely` compatibility
  wrapper. Live Artifact Firewall recovery continues through the absolute-path
  `restore_paths_safely` API.
- Retargeted relative protected-file restoration tests to the underlying
  `restore` operation so success and fail-closed reconstruction semantics remain
  covered.
