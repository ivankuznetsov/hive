---
title: Remove unused publication secure-file wrapper
date: 2026-08-13
---

- Removed the private, uncalled
  `Hive::WorkflowPackage::PublishStore#secure_file!` wrapper. Live publication
  bundle and receipt reads continue through `read_secure_file`, with each call
  supplying its exact size, ownership, mode, and diagnostic constraints.
