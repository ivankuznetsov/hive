---
date: 2026-06-18
slug: daemon-start-config-hermeticity
pages: [testing]
---

During PR #506 babysitting, the broad `bundle exec rake test` pass failed only
in `test/unit/commands/daemon_test.rb` on a developer machine whose global
Hive config had Telegram bot delivery configured. The daemon start test already
stubbed `Hive::Config.load_global_daemon` and `load_global_update`, but
`Hive::Commands::Daemon#start_daemon` also calls
`Hive::Config.load_global_digest_block`; after the digest default-on behavior,
that unstubbed read made the expected dispatcher config depend on the
operator's real `~/.config/hive/config.yml`.

Added daemon-test helpers that stub daemon, update, and digest global config
together for start-path tests, keeping the unit focused on startup wiring and
PID cleanup rather than local operator configuration. Refreshed [[testing]] to
record that `commands/daemon_test.rb` pins the config wiring hermetically.
