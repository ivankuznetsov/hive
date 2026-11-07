---
title: Remote context and answer replay review fixes
type: changelog
created: 2026-11-07
tags: [remote, cli, answer, idempotency]
---

- Context extraction and new-option lifting recognize `--context NAME` and
  `--context=NAME` after idea prose until an explicit `--`. The same parser
  governs remote preflight and native child launches; literal tails stay intact.
- New remote answer receipts retain the exact private native binding and a
  submitted-handle digest. Replays use that retained identity before shared
  receipt validation, independently of read-handle eviction and task advancement.
  Changed answer, handle, target, and principal still conflict.
- Older receipts keep their existing registry-based replay path. Already-evicted
  legacy bindings cannot be reconstructed; this limit is recorded in [[gaps]].
- Focused checks cover parser policy, executable hive/hv remote routing, shared
  answer/receipt behavior, and Rails API mutations, authentication, and reads.
