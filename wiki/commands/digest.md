---
title: hive digest
type: command
source: lib/hive/cli.rb, lib/hive/commands/digest.rb, lib/hive/digest.rb, lib/hive/digest/
created: 2026-06-14
updated: 2026-06-14
tags: [command, digest, telegram, json]
---

**TLDR**: `hive digest [--date YYYY-MM-DD] [--dry-run] [--json]`
builds the daily shipped digest for completed `9-done` tasks across
registered projects. The pipeline collects tasks shipped on one local
calendar date, asks an agent to classify and summarize them when there is
work to report, renders Telegram MarkdownV2, and sends through the bot
Telegram client. Runtime config is loaded through
`Hive::Config.load_global_digest_config`, so real sends can use
`digest.agent`, `budget_usd.digest`, `timeout_sec.digest`,
`bot.digest_chat_id`, and `bot.chat_id_allowlist`. See [[modules/digest]].

## Synopsis

```bash
hive digest [--date YYYY-MM-DD] [--dry-run] [--json]
```

Options:

| Option | Behavior |
|--------|----------|
| `--date YYYY-MM-DD` | Digest this local calendar date. Invalid formats raise `Hive::ConfigError`. |
| omitted `--date` | Uses the local calendar day that just ended via `Hive::Digest::Window.previous_local_day`. |
| `--dry-run` | Avoids Telegram auth/chat lookup and prints the composed message. |
| `--json` | Emits a small versioned JSON delivery document instead of prose. |

## Behavior

1. `Hive::Commands::Digest#parse_date` accepts only `YYYY-MM-DD`; omitted
   dates default to yesterday in the host local timezone.
2. `Hive::Digest.run` asks `Digest::Collector` for shipped items on that date.
   The collector scans every registered project's `.hive-state/stages/9-done/*`
   folders, reads `meta.yml`, reads `pr.md` frontmatter/body, and uses
   `Digest::ShipTimes` to find the ship timestamp from `hive/state` git log
   subjects. Ship time preference is `pr_finalized`, then `archived`, then an
   older `approve -> 9-done` commit shape.
3. If no items shipped, `Digest::Renderer.empty` returns the "Nothing shipped
   today" message and no agent is spawned.
4. If items shipped, `Digest::Categorizer` renders `templates/digest_prompt.md.erb`,
   spawns the resolved `AgentProfile` with `status_mode: :output_file_exists`,
   requires an `items.json` output, then maps rows back by the project-scoped
   categorizer id (`<project_name>/<pr_number>`, or `<project_name>/<slug>` when
   there is no PR number) so two projects sharing a PR number on one day don't
   collide. Allowed categories are `feature`, `fix`, and `patrol`;
   missing/invalid/duplicate-id rows log a warning and default to `feature`
   with a fallback summary.
5. `Digest::Renderer` groups by project, renders categories in fixed order
   (`New features`, `Fixes`, `Patrol tasks`), escapes Telegram MarkdownV2
   dynamic text, and links to PR URLs when present.
6. `Digest::Sender` sends the message with `parse_mode: :markdown_v2` (one
   `send_message` per chunk above Telegram's 4096-char limit), or returns the
   text without credentials in dry-run mode.

If categorization raises `Hive::Digest::ModelError`, `Hive::Digest.run` sends
a failed-generation notice for the date and returns `status: :failed_notice`.

## Output

Human output:

- Dry-run: prints the composed message body.
- Real send: prints `hive digest: <status> for <date>`.

`--json` prints a delivery document for empty/sent/failed_notice: a model
failure still prints this shape with `ok: false` and `status:
"failed_notice"`.

```json
{
  "ok": true,
  "schema": "hive-digest",
  "schema_version": 1,
  "date": "2026-06-13",
  "status": "sent",
  "dry_run": true,
  "chat_id": 12345,
  "message": "..."
}
```

`message` is included only for dry-run output; real-send JSON sets it to
`null`. `chat_id` is the recipient the send resolved (`null` on a dry-run);
it is an optional field, so older consumers that ignore it stay compatible.
`hive-digest` is registered in `Hive::Schemas::SCHEMA_VERSIONS` (v1) and
published under `schemas/hive-digest.v1.json`.

Usage errors emit the shared `ErrorPayload` (same `hive-digest` schema):

- a bad `--date` raises `Hive::ConfigError` and the command emits the
  envelope itself (`error_kind: "config"`, exit 78) before re-raising;
- a malformed invocation caught before dispatch (unknown flag / malformed
  `--json`) emits via `JSON_USAGE_ERROR_CONTRACTS` (`error_kind: "usage"`,
  exit 64).

A Telegram send error that occurs mid-delivery still stays on the stderr +
non-zero exit-code path without an envelope.

Exit codes: `0` empty/sent/failed_notice (a notice was delivered); `78` bad
`--date` or missing chat config; `64` bad flags / malformed `--json`; `70`
unexpected internal error.

## Config And Auth

`Hive::Digest.run` defaults to `Hive::Config.load_global_digest_config` and
the direct API can still override that with `cfg:`. Supported keys:

- `digest.agent` — preferred summarizer agent.
- `patrol.agent` — fallback summarizer agent.
- `budget_usd.digest` — categorizer budget override; default is `50`.
- `timeout_sec.digest` — categorizer timeout override; default is `1800`.
- `bot.digest_chat_id` — preferred Telegram chat id for delivery.
- `bot.chat_id_allowlist[0]` — delivery fallback when no digest chat is set.
- `bot.log_file` — Telegram client log path fallback.

`Digest::Sender` always gets the bot token from
`Hive::Config.telegram_bot_token!`, so the token source is still
`HIVE_TELEGRAM_BOT_TOKEN`.

The daemon schedules the command through `Hive::Daemon::DigestScheduler` when
`digest.enabled: true`, dispatching `hive digest --date <day> --json` once per
owed local day.

## Tests

- `test/unit/cli_test.rb` covers Thor option threading for `hive digest`.
- `test/unit/commands/digest_test.rb` covers dry-run output, success JSON, and
  date validation.
- `test/unit/digest/run_test.rb` covers empty, successful, failed-notice, and
  default-date pipeline behavior through injected seams.
- `test/unit/digest/sender_test.rb` covers chat-id resolution, dry-run token
  avoidance, and MarkdownV2 Telegram send arguments.
- `test/unit/daemon/digest_scheduler_test.rb` covers daemon due/catch-up
  behavior.
- `test/digest/e2e_test.rb` is an opt-in live agent + Telegram test.

## Backlinks

- [[cli]]
- [[commands]]
- [[modules/digest]]
- [[modules/config]]
- [[commands/bot]]
