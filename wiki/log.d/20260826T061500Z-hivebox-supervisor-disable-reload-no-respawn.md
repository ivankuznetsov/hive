---
title: Hivebox supervisor honors a disable SIGHUP without respawning the bot
type: fix
tags: [hivebox, web, supervisor, bot, patrol-fix]
---

`Hive::Web::Supervisor#handle_reload` now records operator disable intent in
`@reload_disabled` when a config reload disables a running bot before TERMing
it. `reap_once` consumes that intent so the signal death is not rescheduled
through `@restart_at`, and `start_child` clears any leftover intent so later
crashes of a restarted child respawn normally. Previously the disable reload
deleted the restart entry but the reap re-added it, respawning the just-disabled
bot five seconds after every SIGHUP disable. Regression-pinned in
`test/unit/web/supervisor_test.rb`.
