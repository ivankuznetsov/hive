---
title: Hive::AtomicFile
type: module
source: lib/hive/atomic_file.rb
created: 2026-07-04
updated: 2026-07-18
tags: [module, filesystem, atomic-write, state, durability]
---

**TLDR**: `Hive::AtomicFile` centralizes small durable state writes. `write(path, content, mode: 0o644, fsync: true)` replaces a file through a same-directory tempfile so readers see the old or new bytes, never a torn write; `fsync_directory(path)` gives callers one best-effort policy for persisting rename and unlink directory entries.

## Contract

`write` creates the parent directory, writes the exact content to a uniquely named sibling tempfile, applies the requested mode at creation, and flushes plus fsyncs the file by default. It then renames the tempfile over the destination and returns `path`. A caller may set `fsync: false` only when it accepts weaker crash durability.

The `ensure` cleanup removes an orphaned tempfile after either success or failure. If writing or renaming fails, the original exception propagates; a failed rename leaves an existing destination unchanged.

`fsync_directory` opens the supplied directory read-only and fsyncs it so preceding rename/unlink changes can survive a crash. Directory fsync is unavailable on some supported Ruby/filesystem combinations, so `NotImplementedError`, `EINVAL`, `ENOTSUP`, and `EBADF` consistently degrade to `nil`; other failures still propagate.

## Representative callers

- Bot pairing state and approval notices use `write`, with owner-private mode where required.
- Durable attempt records, lost-outcome evidence, task projections, workflow-package journals, and managed agent-skill aliases use `write` for structured state replacement.
- Task journal/projection transitions, patrol handoff publication, architecture-patrol stores, and daemon reconciliation paths call `fsync_directory` after rename or unlink boundaries that require directory-entry durability.

The caller set is intentionally broader than this list. Search for `Hive::AtomicFile` when auditing a specific persistence boundary.

## Boundary

Atomic replacement and crash durability are related but distinct. `write` fsyncs the new file before rename, but callers that require the directory entry itself to be durable must also call `fsync_directory` after the rename. Existing modules such as `Hive::Markers` still own older private tempfile-and-rename implementations; migrate those only while changing the owning persistence behavior rather than churning stable code solely for deduplication.

## Tests

`test/unit/atomic_file_test.rb` covers parent creation, exact content and mode, return value, replacement with fsync disabled, failed-rename preservation/cleanup, real directory fsync, and the shared unsupported-platform policy.

## Backlinks

- [[modules/attempts]]
- [[modules/bot]]
- [[modules/daemon]]
- [[modules/markers]]
- [[state-model]]
