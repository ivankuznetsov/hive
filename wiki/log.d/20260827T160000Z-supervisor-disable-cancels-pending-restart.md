---
title: Supervisor disable cancels a pending bot restart
type: log
created: 2026-08-27
updated: 2026-08-27
tags: [log, web, supervisor, patrol]
---

## 2026-08-27 — SIGHUP disable now cancels a crashed bot's queued respawn

**Area:** `lib/hive/web/supervisor.rb` (Hivebox container supervisor)

Follow-up to the 2026-08-25 desired-running-state fix. The live-PID disable
path was correct, but the disable branch of `handle_reload` gated all of its
work on the bot having a pid. A bot that had ALREADY crashed and was awaiting
its scheduled respawn (pid nil, `@restart_at["bot"]` queued — e.g. a
fast-failure backoff) slipped through untouched: `desired` stayed true and
the queued entry survived, so `start_due_restarts` later fired it and
respawned a bot the config no longer enables — disable intent silently
undone without any signal being sent.

**Fix:** the disabled branch now matches the bot child regardless of pid and
flips `desired = false` and deletes the queued `@restart_at` entry in every
case, TERMing the process group only when a pid is actually present. Disable
intent is authoritative over how the bot is currently down. The enabled
branch also deletes a pending restart entry before starting the bot directly,
so a superseded due-time cannot linger. Re-enable transitions stay correct:
`start_child` re-arms `desired = true` on both create and rebind.

**Tests:** `test/unit/web/supervisor_test.rb` pins the pending-restart
cancellation end to end (disable reload → queued entry gone →
`start_due_restarts` starts nothing), the re-enable transition (stopped bot
started again with desired re-armed), and desired re-arming on
`start_child` rebind. Reload contract documented in `wiki/commands/web.md`.
