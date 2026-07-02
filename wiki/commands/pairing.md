---
title: hive pairing
type: command
source: lib/hive/cli.rb, lib/hive/commands/pairing.rb, lib/hive/bot/pairing_store.rb, lib/hive/bot/pairing_approval_queue.rb
created: 2026-07-02
updated: 2026-07-02
tags: [command, bot, telegram, pairing, json]
---

**TLDR**: `hive pairing` is the owner-side approval surface for Telegram bot
first-contact pairing. Unknown DM chats can send `/start` when
`bot.pairing_enabled: true`; the bot returns a one-time code, and the owner
runs `hive pairing approve telegram <CODE>` to append that chat id to the
global bot allowlist.

## Synopsis

```bash
hive pairing list [--json]
hive pairing approve telegram <CODE> [--json]
```

`telegram` is a fixed literal, not a platform registry.

## Behavior

- Pending requests live in `<state_home>/.bot.pairings.json` as
  `code -> {chat_id, created_at}` with 8-character `A-Z` codes and 24-hour
  expiry.
- `list` prints pending code, chat id, creation time, age, and expiry; with
  `--json` it emits `hive-pairing-list.v1`.
- `approve telegram <CODE>` peeks the unexpired code, validates global bot
  config, appends the chat id to `bot.chat_id_allowlist` through
  `Config.update_global_config!`, sends `SIGHUP` to the running bot when a
  live bot PID file exists, writes a `hive-pairing-approval` notice, and only
  then consumes the pending code.
- Unknown or expired codes fail without mutating `config.yml` or writing an
  approval notice. Invalid argument shapes fail as usage errors.

The approval notice queue is a separate owner-side
`<state_home>/pairing_approvals/` directory, not an extension of the daemon
dispatch-request schema. The bot reaper drains it and removes notices only
after the Telegram send succeeds; stale notices are dropped after one hour.
It does not re-check the in-memory allowlist before sending the "approved" DM,
because the config write and SIGHUP reload are asynchronous.

## JSON

`hive pairing list --json` emits:

```json
{
  "schema": "hive-pairing-list",
  "schema_version": 1,
  "ok": true,
  "pending": [
    {
      "code": "ABCDEFGH",
      "chat_id": 12345,
      "created_at": "2026-07-02T00:00:00Z",
      "age_sec": 10,
      "expires_in_sec": 86390
    }
  ]
}
```

`hive pairing approve telegram <CODE> --json` emits
`hive-pairing-approve.v1` with the approved `chat_id`, whether it was already
allowlisted, whether a live bot reload was requested, and the queued notice id.
Both subcommands emit command-local error envelopes for invalid arguments,
config failures, unknown/expired codes, store read failures, and notice-write
failures.

## Tests

- `test/unit/cli_test.rb` covers CLI option threading.
- `test/unit/commands/pairing_test.rb` covers list/approve JSON, argument
  validation, code lifecycle, allowlist mutation, reload signaling, and
  approval-notice failure behavior.
- `test/unit/daemon/pairing_approval_queue_test.rb` covers notice schema,
  sorting, expiry, malformed-file handling, and removal.
- `test/integration/bot/pairing_flow_test.rb` covers the Telegram first-contact
  happy path plus unknown/expired code rejection without allowlist mutation.

## Related

- [[commands/bot]]
- [[modules/bot]]
- [[modules/config]]
