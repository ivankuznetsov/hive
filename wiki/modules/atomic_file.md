---
title: Hive::AtomicFile
type: module
source: lib/hive/atomic_file.rb
created: 2026-07-02
updated: 2026-07-02
tags: [module, state, filesystem, atomic-write]
---

**TLDR**: `Hive::AtomicFile.write` is the shared helper for small state-file
writes that must not leave torn or truncated content. It writes a sibling
tempfile in the target directory, optionally flushes and fsyncs it, renames it
over the destination, removes an orphaned tempfile on failure, and returns the
target path.

## Contract

`Hive::AtomicFile.write(path, content, mode: 0o644, fsync: true)` creates the
parent directory, opens a unique hidden tempfile with the requested file mode,
writes the complete content, optionally `flush`es and `fsync`s, then
`File.rename`s the tempfile into place. A crash or rename failure leaves either
the previous target content or the new content; callers should not observe a
partially-written target file.

Use `mode: 0o600` for owner-private state. Use `fsync: false` only for callers
that have measured the cost and can tolerate losing the last write on a crash.

## Current Users

- `Hive::Bot::PairingStore#write_entries` writes
  `<state_home>/.bot.pairings.json` with mode `0600`.
- `Hive::Bot::PairingApprovalQueue.write!` writes approval notice JSON files
  under `<state_home>/pairing_approvals/` with the default mode.

The helper was introduced during the `arch-review-pairing` architecture pass so
new state writers have one obvious primitive instead of copying the
tempfile/rename/fsync pattern again. Older call sites such as [[modules/markers]],
[[modules/events]], setup/init/service installer writes, and review suppression
still carry local variants until a dedicated migration pass.

## Tests

`test/unit/atomic_file_test.rb` covers parent-directory creation, mode
application, return value, successful replacement, opt-out fsync path, rename
failure preserving the previous target, and tempfile cleanup after success or
failure.

## Backlinks

- [[modules/bot]]
- [[modules/markers]]
- [[modules/events]]
