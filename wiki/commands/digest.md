---
title: hive digest
type: command
source: lib/hive/commands/digest.rb
---

# `hive digest`

`hive digest` is a registry and scheduling adapter for the standalone PRDigest
CLI. Hive does not fetch pull requests, generate prose, render Telegram markup,
split messages, or decide delivery retries. It always selects PRDigest's
deterministic `run` command; it never selects the separate facts/prose surfaces
or configures an AI provider.

```text
Hive registered projects
  -> github.com/owner/name validation and --repo filtering
  -> private temporary PRDigest YAML
  -> prdigest run --date D --repo ... --json
  -> unchanged prdigest-result payload and exit status
```

## Usage

```sh
hive digest
hive digest --date 2026-06-13
hive digest --repo owner/one --repo owner/two
hive digest --dry-run
hive digest --date 2026-06-13 --json
```

| Option | Meaning |
|---|---|
| `--date YYYY-MM-DD` | Date passed to PRDigest. Without it, Hive passes the previous completed Europe/London day. |
| `--repo owner/name` | Repeatable, case-insensitive filter over Hive's registered GitHub repository identities. It cannot expand scope. |
| `--dry-run` | Fetch and render through PRDigest, print its chunks, and omit Telegram credentials/delivery. |
| `--json` | Emit PRDigest's `prdigest-result` v1 document without a Hive wrapper. |

Every GitHub-backed registry row must resolve to `github.com/owner/name`,
either from its persisted `repository_identity` or its checkout's `origin`.
Well-formed projects that are demonstrably outside that scope—a local remote,
another Git host, or an existing Git repository with no `origin`—are ignored.
Malformed rows, invalid GitHub identities, unavailable identity lookups, empty
GitHub scope, and unregistered `--repo` filters fail closed before PRDigest
starts.

## Configuration and credentials

Hive writes a mode-`0600` temporary configuration containing only:

- `timezone: Europe/London`;
- the resolved repository list;
- the first `bot.chat_id_allowlist` entry;
- PRDigest cursor/delivery paths below Hive's state home; and
- environment variable names for GitHub and Telegram tokens.

Token values never enter YAML. GitHub authentication resolves from
`GITHUB_TOKEN`, then `GH_TOKEN`, then `gh auth token --hostname github.com`.
Real delivery loads Hive's private `.env` and forwards
`HIVE_TELEGRAM_BOT_TOKEN` only in the child environment. Dry-run uses a
non-deliverable placeholder chat when Telegram is not configured.
The child configuration has no schedule, prose, or provider block. In
particular, Hive's `digest.max_catchup_days` remains a daemon-only policy even
when configured as `0` (unbounded) or above PRDigest's standalone scheduling
range.

`PRDIGEST_BIN` can point at an explicit development executable. Normal packaged
installs receive PRDigest through Hive's `prdigest ~> 0.2.0` runtime dependency;
when its executable is not on `PATH`, Hive resolves the installed gem's
executable directly. Missing binary or authentication is a Hive adapter
configuration error; Hive never falls back to an internal engine.

## Results and exits

Successful and child-failure JSON is byte-shape-equivalent to PRDigest's parsed
result:

```json
{
  "schema": "prdigest-result",
  "schema_version": 1,
  "status": "success",
  "mode": "explicit_date_replay",
  "requested_days": ["2026-06-13"],
  "settled_days": ["2026-06-13"],
  "skipped_days": [],
  "failed_date": null,
  "remaining_days": [],
  "error": null,
  "chunks": [],
  "delivery": {
    "accepted_chunks": 3,
    "total_chunks": 3,
    "status": "completed"
  }
}
```

PRDigest exits `0..6` are preserved: `2` configuration/CLI, `3` GitHub, `4`
Telegram or delivery checkpoint, `5` cursor state, and `6` failure after earlier
durable progress. Hive-only adapter failures remain `78` (configuration) or
`70` (invalid child output/internal). Thor rejects malformed Hive flags with
`64` and emits the same result shape with `error.kind=cli` in JSON mode.

## Delivery and daemon behavior

PRDigest owns the stable rendered payload, Telegram-safe HTML chunks,
next-unsent checkpoint, permanent/ambiguous classification, and bounded retry.
The `delivery` result preserves `accepted_chunks`, `total_chunks`,
`failed_chunk`, and `status`.

Hive's daemon owns only its once-per-London-day cursor in
`digest_state.json`. It dispatches one explicit date at a time. A normal
retryable PRDigest failure backs off. `digest.max_catchup_days` bounds that
Hive-owned dispatch loop and is never sent to PRDigest. These non-replayable
kinds park the date without advancing or redispatching:

- `telegram_permanent`
- `telegram_refused`
- `telegram_ambiguous`
- `delivery_checkpoint_permanent`

PRDigest delivery checkpoints live below `<state_home>/prdigest/deliveries`.
The separate Hive scheduler cursor advances only after PRDigest exits zero.

## Migration

Hive's removed MarkdownV2/LLM digest implementation and its
`hive-digest` v1/v2 schemas are not compatibility aliases. Consumers must read
`prdigest-result` v1. The removed `digest.agent`, `budget_usd.digest`,
`timeout_sec.digest`, prompt template, GitHub digest transport, renderer,
checkpoint store, and sender have no runtime effect.

Before upgrading a daemon with `blocked_date` or an unfinished legacy
`digest-deliveries` checkpoint, reconcile that Telegram delivery manually.
The formats are intentionally not auto-converted because an in-flight legacy
chunk may already have reached Telegram. After reconciliation, archive the
legacy checkpoint and blocked scheduler state before enabling the new adapter.

See [[modules/digest]], [[modules/daemon]], [[modules/config]], and [[testing]].
