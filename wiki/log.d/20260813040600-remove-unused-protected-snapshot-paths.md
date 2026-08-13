---
title: Remove unused protected-path snapshot helper
date: 2026-08-13
---

- Removed the uncalled `Hive::ProtectedFiles.snapshot_paths` digest helper.
  Absolute protected anchors continue through the Artifact Firewall's richer
  `observe_paths` identity boundary, which detects content, mode, and file-type
  substitution without following links.
