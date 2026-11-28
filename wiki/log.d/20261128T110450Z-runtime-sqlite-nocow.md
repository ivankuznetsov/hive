---
title: Diagnose and prepare runtime SQLite storage on btrfs
type: log
created: 2026-11-28
tags: [runtime, sqlite, btrfs, doctor, setup]
---

Doctor now reports per-path NOCOW evidence and validates writable SQLite
storage through a private snapshot. Setup and daemon start prepare eligible
empty directories before lock or log creation. The [runtime guide](../commands/runtime.md#btrfs-nocow-migration)
covers a manual move with a generation-bound DB/proof pair and a final
manifest for every separately stopped state-root writer.

A disposable btrfs installation reached `active` with C verified on the
state directory, published database, WAL and SHM.
