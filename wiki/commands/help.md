---
title: hive help
type: command
source: bin/hive, lib/hive/cli_argv_policy.rb, thor-1.5.0/lib/thor.rb
created: 2026-09-02
updated: 2026-09-02
tags: [command, help, thor, read-only]
---

> **Public CLI authority:** See [docs/cli.md](../../docs/cli.md#hive-help) for canonical invocation syntax, options, JSON schemas, context rules, and exit codes. This page documents internal implementation, storage, and architecture.

**TLDR**: `hive help` is the rendered public command inventory. With a command
name it prints that command's usage, options, description, and examples.

## Architecture

Without a command, Thor renders the visible top-level commands in its bounded
`Commands:` section followed by global options. Hidden/internal commands are
omitted; inherited public commands such as `help` and `tree` are included.
With a command, Thor resolves Hive's public hyphenated spelling (including
mapped method names) and renders the command-specific help text. `Hive::CliArgvPolicy.rewrite_help` rewrites `hive COMMAND --help` and `hive COMMAND -h` to `hive help COMMAND` ahead of command validation or mutation.

`test/unit/docs_cli_authority_test.rb` and `test/integration/wiki_command_index_test.rb` verify rendered help and Thor metadata against [docs/cli.md](../../docs/cli.md) and the architecture navigation map in [[cli]].

## Tests

`test/unit/cli_test.rb` covers command-local help content,
`test/unit/docs_cli_authority_test.rb` enforces public CLI parity with
[docs/cli.md](../../docs/cli.md), and
`test/integration/wiki_command_index_test.rb` checks rendered help against
`Hive::CLI` metadata and [[cli]] navigation.

## Backlinks

- [[cli]] · [[commands/tree]]
