---
title: hive tree
type: command
source: thor-1.5.0/lib/thor.rb
created: 2026-09-02
updated: 2026-09-02
tags: [command, help, thor, read-only]
---

**TLDR**: `hive tree` prints Thor's diagnostic tree of visible commands using
internal command keys and one-line descriptions.

## Usage

```bash
hive tree
```

## Options

There are no tree-specific options. The inherited global `--json` option is
accepted but ignored: tree output remains text.

## Behavior

Thor prints the CLI namespace followed by every visible command except the
inherited `help` command and `tree` itself, sorted by its internal command key.
Hidden commands are omitted. Because this
is a framework diagnostic, mapped Hive names may appear with underscores (for
example `answer_digest`) rather than the public hyphenated spelling rendered
by `hive help`.

Use [[commands/help]] and [[cli]] for the public surface and owner mapping;
`tree` is not the source used by the completeness guard.

## Output and schema

Output is a Unicode text tree on stdout. JSON output and a schema are not
applicable.

## Error and serialization policy

Serialization fallback is not applicable because no JSON is emitted. Extra
arguments are rejected as usage errors rather than interpreted as filters.

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | The visible command tree rendered. |
| 64 | The invocation has unexpected arguments. |

## Examples

```bash
hive tree
hive tree --json   # still text
```

## Tests

`test/integration/wiki_command_index_test.rb` confirms that the inherited
command remains visible and has exactly one Wiki owner.

## Backlinks

- [[cli]] · [[commands/help]]
