---
title: hive answer-digest
type: command
source: lib/hive/commands/answer_digest.rb, lib/hive/daemon/answer_digest_scheduler.rb
created: 2026-06-27
updated: 2026-06-27
tags: [command, digest, telegram, bot, daemon]
---

**TLDR**: `hive answer-digest [--date YYYY-MM-DD] [--dry-run] [--json]`
posts one Telegram message for tasks currently waiting on human input. It
uses the same waiting-row selector and callback buttons as `/waiting`, sends
nothing when the waiting set is empty, and is scheduled by
`Hive::Daemon::AnswerDigestScheduler` once per local calendar day at/after
`answer_digest.hour` (default 9) when `answer_digest.enabled: true`.

## Synopsis

```bash
hive answer-digest [--date YYYY-MM-DD] [--dry-run] [--json]
```

Options:

| Option | Behavior |
|--------|----------|
| `--date YYYY-MM-DD` | Echoed into the JSON `date` field; does not scope the (always-live) waiting set or dedup sends. Scheduler idempotency lives in the daemon's `answer_digest_state.json`, not this command — `tick`/`complete` never consume the command's `--date`. |
| omitted `--date` | Uses today's local calendar date. |
| `--dry-run` | Avoids `.env`, token/chat lookup, and Telegram send; prints the would-send text plus button count. |
| `--json` | Emits a small JSON result. Empty snapshots report `sent:false, reason:"empty"`. |

## Behavior

1. Loads the global digest-shaped config via
   `Hive::Config.load_global_digest_config` so the existing bot runtime paths
   and `bot.chat_id_allowlist[0]` resolution apply.
2. For real sends only, calls `Hive::EnvFile.load!` before reading
   `HIVE_TELEGRAM_BOT_TOKEN`, matching `hive digest`'s daemon-auth behavior.
3. Fetches the global status snapshot through `Hive::Bot::StatusWatcher`.
4. Filters rows through `Hive::Bot::WaitingRows.select`, including
   brainstorm, plan, review, execute, finalize, and generic `needs_input`
   gates while excluding recovery and ready-to-advance rows. Plan pauses are
   suppressed for projects whose own config has `daemon.enabled: true`.
5. If no rows wait, exits 0 without sending Telegram.
6. Otherwise renders `Waiting on you (N)` with up to 10 task lines and sends a
   flat inline keyboard with one primary callback button per visible task.
   Buttons are built by `WaitingRows.button_for`, which reuses
   `RowActions.resolve(row).primary`, so callbacks match the original
   push-notification buttons byte-for-byte.

   **Caveat (long-callback buttons).** `hive answer-digest` runs as a separate
   subprocess from the long-running bot. Callbacks over Telegram's 64-byte
   limit are compacted to a `#prefix:` token stored only in *that subprocess's*
   in-memory `NotificationBuilders` registry, which exits when the command
   returns; the bot that handles the tap looks the token up in *its own*
   registry, misses, and replies "button expired" (see the cross-process
   registry note at `router.rb`). For project `hive`'s ~40-char slugs the
   `approve_plan:`, `findings:accept_all:`, and `rerun:…` callbacks all exceed
   64 bytes, so only the short `answer:` button is reliably tap-actionable from
   the digest today. The short task lines still tell the operator what is
   waiting; open a laptop / use `/waiting` in the bot chat to act on the
   long-callback rows.

The command is intentionally separate from `hive digest`: it does not collect
completed work, spawn a categorizer agent, or write the shipped-digest state
file. See [[commands/digest]] and [[modules/digest]] for the completed-work
digest.

## Daemon Scheduling

`Hive::Daemon::AnswerDigestScheduler` persists
`<state_home>/answer_digest_state.json`:

```json
{ "last_fired_date": "2026-06-27", "updated_at": "2026-06-27T09:00:05Z" }
```

When enabled, each daemon tick checks local time. At or after
`answer_digest.hour`, if today's local date has not already fired and no
answer-digest child is pending, it dispatches:

```bash
hive answer-digest --date YYYY-MM-DD --json
```

Exit 0 advances `last_fired_date`, including empty snapshots. Non-zero or nil
exits leave the cursor behind and retry after the bounded backoff schedule
`60, 300, 900` seconds. The dispatcher tracks answer-digest children on the
same global `kind: :digest` concurrency slot as `hive digest`, so digest-like
Telegram jobs do not overlap and neither consumes normal task capacity.

## Config

Global config:

```yaml
answer_digest:
  enabled: false
  hour: 9
```

`enabled` is explicit opt-in. `hour` is local time, integer `0..23`. The
delivery chat and token still come from the Telegram bot config/environment:
`bot.chat_id_allowlist[0]` and `HIVE_TELEGRAM_BOT_TOKEN`.

## Tests

- `test/unit/commands/answer_digest_test.rb` covers empty, dry-run, real-send,
  overflow, date parsing, default collaborators, status failures, and
  per-project daemon-enabled suppression degradation.
- `test/unit/daemon/answer_digest_scheduler_test.rb` covers the 09:00 local
  threshold, once-per-day idempotency across restarts, next-day firing,
  disabled mode, cancel, failure backoff, state corruption, and timezone
  behavior.
- `test/unit/daemon/dispatcher_test.rb` covers answer-digest dispatch,
  completion, dry-run pseudo-child completion, spawn failures, global digest
  slot blocking, config-exit phantom-project handling, and SIGHUP reconfigure.

## Backlinks

- [[commands/bot]]
- [[commands/daemon]]
- [[modules/daemon]]
- [[modules/config]]
