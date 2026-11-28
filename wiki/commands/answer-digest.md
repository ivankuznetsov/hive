---
title: hive answer-digest
type: command
source: lib/hive/cli.rb, lib/hive/commands/answer_digest.rb, schemas/hive-answer-digest.v1.json
created: 2026-09-02
updated: 2026-09-02
tags: [command, answers, telegram, daemon, json]
---

> **Public CLI authority:** See [docs/cli.md](../../docs/cli.md#hive-answer-digest) for canonical invocation syntax, options, JSON schemas, context rules, and exit codes. This page documents internal implementation, storage, and architecture.

**TLDR**: `hive answer-digest` reads the live waiting-on-human set and sends
one Telegram digest. `--dry-run --json` is the side-effect-free agent read
path; the command's `--date` labels output but neither filters nor deduplicates
the live set.

## Implementation notes

The command takes the current global status snapshot, selects tasks waiting on
human input, and builds at most ten Telegram buttons while retaining the true
waiting count and complete `tasks[]` list in JSON. An empty set is silent and
successful. A non-empty normal invocation sends one Telegram message; a dry
run renders the same selection without loading `.env`, resolving Telegram
credentials, or sending a message.

`--date` is only an output label. Once-per-local-day scheduling and
deduplication belong to the daemon's `answer_digest_state.json`, not this
command. Exact brainstorm answers use the separate [[commands/answer]]
inventory-and-binding contract.

## Tests

`test/unit/commands/answer_digest_test.rb` covers selection, send/dry-run/empty
results, the v1 schema, error classification, and emission suppression.

## Backlinks

- [[cli]] · [[commands/answer]] · [[commands/daemon]] · [[modules/daemon]]
