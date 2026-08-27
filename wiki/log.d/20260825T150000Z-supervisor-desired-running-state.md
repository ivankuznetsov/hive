---
title: Supervisor desired-running state stops disabled-bot respawn
type: log
created: 2026-08-25
updated: 2026-08-25
tags: [log, web, supervisor, patrol]
---

## 2026-08-25 — Container supervisor no longer respawns a bot the operator disabled

**Area:** `lib/hive/web/supervisor.rb` (Hivebox container supervisor)

The SIGHUP reload path that disables a running Telegram bot deleted
`@restart_at["bot"]` and then TERMed it — but `should_restart?` classified
the resulting signal death as a crash (`@stopping` false, not a success
exit) and `schedule_restart` re-added the entry during the next reap, so the
supervisor respawned a bot the operator had just turned off (immediately for
a long-lived bot, after the fast-failure backoff otherwise).

**Fix:** `Supervisor::Child` gained a `desired` field recording whether the
supervisor wants the child running. `handle_reload` flips `desired` to
`false` BEFORE sending TERM; `should_restart?(child, status)` now also skips
children whose desired state is false; `start_child` resets `desired` to
true on both create and rebind so later restarts/crashes still come back.
nil `desired` (legacy construction) counts as desired.

**Tests:** `test/unit/web/supervisor_test.rb` pins the new decision-helper
semantics and adds an end-to-end regression: reload-disable → reap →
`start_due_restarts` must never respawn the bot.
