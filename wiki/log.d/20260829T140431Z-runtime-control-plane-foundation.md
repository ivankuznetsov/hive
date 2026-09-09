---
title: Add the runtime control-plane database foundation
date: 2026-08-29
---

- Added the boundary-ready `Hive::RuntimeControlPlane` Sequel Core lifecycle,
  exact SQLite schema and application identity, canonical codecs, stable
  registration/task identity validation, and typed diagnostics.
- The foundation is lazy and validation-only reads do not create a database;
  existing runtime readers and writers remain unchanged until the coordinated
  cutover units land.
- Added Sequel 5.107 as an explicit runtime dependency in both the CLI and
  packaged-Web dependency closures.
