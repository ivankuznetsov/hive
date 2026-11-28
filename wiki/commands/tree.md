---
title: hive tree
type: command
source: thor-1.5.0/lib/thor.rb
created: 2026-09-02
updated: 2026-09-02
tags: [command, help, thor, read-only]
---

> **Public CLI authority:** See [docs/cli.md](../../docs/cli.md#hive-tree) for canonical invocation syntax, options, JSON schemas, context rules, and exit codes. This page documents internal implementation, storage, and architecture.

**TLDR**: `hive tree` prints Thor's diagnostic tree of visible commands using
internal command keys and one-line descriptions.

## Architecture

Thor prints the CLI namespace followed by every visible command except the
inherited `help` command and `tree` itself, sorted by its internal command key.
Hidden commands are omitted. Because this
is a framework diagnostic, mapped Hive names may appear with underscores (for
example `answer_digest`) rather than the public hyphenated spelling rendered
by `hive help`.

Use [docs/cli.md](../../docs/cli.md) for the authoritative public CLI surface
and [[cli]] for internal architecture mapping; `tree` is not the source used by
the parity guard.

## Tests

`test/integration/wiki_command_index_test.rb` and
`test/unit/docs_cli_authority_test.rb` confirm that `tree` remains visible and
covered in [docs/cli.md](../../docs/cli.md).

## Backlinks

- [[cli]] · [[commands/help]]
