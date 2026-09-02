---
title: hive help
type: command
source: bin/hive, lib/hive/cli_argv_policy.rb, thor-1.5.0/lib/thor.rb
created: 2026-09-02
updated: 2026-09-02
tags: [command, help, thor, read-only]
---

**TLDR**: `hive help` is the rendered public command inventory. With a command
name it prints that command's usage, options, description, and examples.

## Usage

```bash
hive help
hive help COMMAND
hive COMMAND --help
hive COMMAND -h
```

## Options

There are no help-specific options. The inherited global `--json` option is
accepted but ignored: help is text-only. The public wrapper rewrites a known
command's local `--help` or `-h` request to `help COMMAND` before normal command
validation or mutation.

## Behavior

Without a command, Thor renders the visible top-level commands in its bounded
`Commands:` section followed by global options. Hidden/internal commands are
omitted; inherited public commands such as `help` and `tree` are included.
With a command, Thor resolves Hive's public hyphenated spelling (including
mapped method names) and renders the command-specific help contract.

The top-level command list is the authority for which commands require one
owner row in [[cli]].

## Output and schema

Output is human-readable text on stdout. JSON output and a schema are not
applicable; passing `--json` does not change the format.

## Error and serialization policy

Serialization fallback is not applicable because the command emits no JSON.
An unknown command is reported as Thor usage text and does not fall through to
another command or owner.

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | Top-level or command-specific help rendered. |
| 64 | The requested command is unknown or the invocation is malformed. |

## Examples

```bash
hive help
hive help plan-review
hive daemon --help
```

## Tests

`test/unit/cli_test.rb` covers command-local help content and
`test/integration/wiki_command_index_test.rb` compares this rendered public
surface with the Wiki owner index.

## Backlinks

- [[cli]] · [[commands/tree]]
