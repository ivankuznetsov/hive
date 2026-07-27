---
title: Recovery migration prunes inert post-cutover v1 skeletons
type: fix
date: 2026-07-26
tags: [recovery, migration, attempts, dogfood]
---

Fresh-main dogfood found that a still-running pre-cutover web reader could
recreate the empty `attempts/v1` directory skeleton after v2 became
authoritative. That left no records to migrate, but the dual-root guard still
blocked daemon startup.

`Hive::Recovery::Migration` now removes a legacy tree only when every entry is
an empty real directory. It uses bottom-up `rmdir`, so a file, symlink, or
concurrent writer fails closed and preserves the ambiguous root for operator
inspection. Regression tests cover successful inert cleanup plus file,
symlink, and concurrent-write refusal.
