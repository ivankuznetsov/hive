---
title: Hive::Bot
type: module
source: lib/hive/bot/
created: 2026-05-14
updated: 2026-05-14
tags: [bot, telegram, module, mobile]
---

**TLDR**: `Hive::Bot::*` is the Telegram operator surface for daemon
human-input gates. The supervisor has three loops: Telegram long-poll,
`hive status --json` notification polling, and child reaping. Pure
routing/parsing logic is split away from Telegram, filesystem, Codex,
and subprocess I/O.

## Module map

| Module | File | Purpose |
|--------|------|---------|
| `Supervisor` | `lib/hive/bot/supervisor.rb` | Long-running loop. Polls Telegram, runs status ticks, reaps child commands, handles TERM/INT/HUP, writes last-seen update IDs. |
| `Telegram` | `lib/hive/bot/telegram.rb` | Thin `telegram-bot-ruby` wrapper for `getUpdates`, `sendMessage`, message splitting, markdown escaping, and typed `Update` records. |
| `Router` | `lib/hive/bot/router.rb` | Closed-enum intent classifier and pure dispatch into slash/callback/free-text handlers. Performs allowlist auth before any handler sees an update. |
| `Handlers::*` | `lib/hive/bot/handlers/` | Slash command, callback, and free-text logic returning descriptors; no direct Telegram I/O. |
| `StatusWatcher` | `lib/hive/bot/status_watcher.rb` | Runs `hive status --json`, validates the envelope, returns typed rows. |
| `NotificationDispatcher` | `lib/hive/bot/notification_dispatcher.rb` | Dedupe and send newly-entered waiting/recovery/ready rows. Suppresses ready notifications when the daemon is enabled for that project. |
| `NotificationBuilders` | `lib/hive/bot/notification_builders.rb` | Marker/action-specific text and inline keyboards. Fingerprints rows by project/slug/marker/attrs. |
| `BrainstormParser` | `lib/hive/bot/brainstorm_parser.rb` | Pure parser for `## Round`, `### Q<N>.`, and `### A<N>.` blocks. |
| `BrainstormAnswerWriter` | `lib/hive/bot/brainstorm_answer_writer.rb` | Locked, first-write-wins insertion into the next answer block, with atomic rewrite. |
| `ConversationStore` | `lib/hive/bot/conversation_store.rb` | In-memory per-chat active answer/Codex state with TTL. No sidecar file; `brainstorm.md` stays canonical. |
| `CodexConversation` | `lib/hive/bot/codex_conversation.rb` | Short-lived Path A Codex spawn wrapper. Parses `BOT_REPLY`, `BOT_DRAFT`, and `BOT_ERROR` lines. |
| `ChildSupervisor` | `lib/hive/bot/child_supervisor.rb` | Spawns child `hive ...` commands with `pgroup: true`, writes per-dispatch logs, reaps with `Process.wait2(-1, WNOHANG)`. |
| `Logger` | `lib/hive/bot/logger.rb` | JSON-line structured logger with size rotation and closed event enum. |
| `Commands::Bot` | `lib/hive/commands/bot.rb` | Thor command surface and PID-file lifecycle. |

## Wiring

```
hive bot start
  └─ Hive::Commands::Bot (daemonizes unless --foreground)
       ├─ validates global bot config + HIVE_TELEGRAM_BOT_TOKEN
       ├─ writes ~/.local/state/hive/.bot.pid
       └─ Hive::Bot::Supervisor.run_forever
            ├─ poll loop: Telegram.getUpdates → Router → handler descriptors
            ├─ status loop: hive status --json → NotificationDispatcher
            └─ reaper loop: ChildSupervisor.reap_all → Telegram reply
```

## Trust boundary

The bot does not move task folders or invent approval policy. State
mutations go through existing `hive` commands (`new`, workflow verbs,
`markers clear`, `accept-finding`, `reject-finding`, `run`) except for
brainstorm answer insertion. That insertion is deliberately narrow:
`BrainstormAnswerWriter.append!` holds `Hive::Lock.with_task_lock`,
re-parses the file under the lock, refuses non-empty answer slots, and
inserts the literal confirmed text. Two devices racing the same question
therefore produce one answer and one "already answered" reply, not a
merged or overwritten block.

## Eval harness

`test/eval/` exercises this module through the same supervisor entrypoints production uses, with only Telegram and child-process I/O replaced by in-process fakes. The harness classifies outbound messages into the eval contract reasons (`agent_blocked_question`, `status_response`, `task_finished`, `fatal_error`) from observable status rows, handler intents, and child exits. That mapping stays test-only; production bot payloads are unchanged.

## Backlinks

- [[commands/bot]]
- [[commands/status]] · [[modules/task_action]]
- [[modules/daemon]]
- [[decisions]] (ADR-026)
