---
title: hive answer-digest
type: command
source: lib/hive/cli.rb, lib/hive/commands/answer_digest.rb, schemas/hive-answer-digest.v1.json
created: 2026-09-02
updated: 2026-09-02
tags: [command, answers, telegram, daemon, json]
---

**TLDR**: `hive answer-digest` reads the live waiting-on-human set and sends
one Telegram digest. `--dry-run --json` is the side-effect-free agent read
path; the command's `--date` labels output but neither filters nor deduplicates
the live set.

## Usage

```bash
hive answer-digest [--date YYYY-MM-DD] [--dry-run] [--json]
```

## Options

- `--date YYYY-MM-DD` is echoed in the output. It does not scope the waiting
  rows and does not deduplicate sends.
- `--dry-run` renders the digest without loading `.env`, resolving Telegram
  credentials, or sending a message.
- `--json` selects the single-document `hive-answer-digest.v1` contract.

## Behavior

The command takes the current global status snapshot, selects tasks waiting on
human input, and builds at most ten Telegram buttons while retaining the true
waiting count and complete `tasks[]` list in JSON. An empty set is silent and
successful. A non-empty normal invocation sends one Telegram message; a dry
run prints or serializes the same selection without a send.

`--date` is only an output label. Once-per-local-day scheduling and
deduplication belong to the daemon's `answer_digest_state.json`, not this
command. Exact brainstorm answers use the separate [[commands/answer]]
inventory-and-binding contract.

## Output and schema

JSON output uses `hive-answer-digest.v1`. Success contains `date`, `sent`,
`reason`, `dry_run`, `chat_id`, `button_count`, `count`, `tasks[]`, and
`message`. `reason` is `null` for a real send, `empty` when nothing is waiting,
or `dry_run` for an unsent non-empty preview. `message` contains rendered text
only for a non-empty dry run; it is `null` after a real send and for an empty
set.

Error envelopes use `error_kind` values `usage`, `config`,
`status_unavailable`, or `internal`, and carry the typed error class and exit
code. Human mode prints a send confirmation or dry-run content; an empty set
prints nothing.

## Error and serialization policy

Typed Hive errors retain their original exit boundary; untyped failures are
wrapped as `Hive::InternalError`. Both success and error emission suppress
`Errno::EPIPE` and `JSON::GeneratorError`. This is deliberate: emission is the
only work after a Telegram send, so an output failure cannot turn a delivered
digest into a retryable failure and cause a duplicate send. On an error path,
suppression preserves the original typed error and exit code.

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | Sent, empty, or dry-run success. |
| 64 | Invalid flag or malformed invocation (`usage`). |
| 69 | Status snapshot unavailable; retryable (`status_unavailable`). |
| 70 | Unexpected internal failure (`internal`). |
| 78 | Invalid date or missing Telegram chat configuration (`config`). |

## Examples

```bash
hive answer-digest
hive answer-digest --date 2026-09-02 --json
hive answer-digest --dry-run --json
```

## Tests

`test/unit/commands/answer_digest_test.rb` covers selection, send/dry-run/empty
results, the v1 schema, error classification, and emission suppression.

## Backlinks

- [[cli]] · [[commands/answer]] · [[commands/daemon]] · [[modules/daemon]]
