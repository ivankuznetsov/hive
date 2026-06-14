## [2026-06-14T22:28:07Z] wiki — refresh digest command and API coverage

**Action:** Refreshed command/API surface coverage after the digest commit
series through `ab35b657` added the public `hive digest` Thor command,
`Hive::Commands::Digest`, `Hive::Digest::Sender`, and daemon-side
`Hive::Daemon::DigestScheduler`. Current workspace source also adds the global
digest config plumbing (`Config.load_global_digest`,
`Config.load_global_digest_config`, `digest.*`, and `bot.digest_chat_id`). Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "routes
handlers commands executable entrypoints README API surface"` surfaced prior
wiki-refresh patterns, and the configured master wiki path only had general
route/API coverage guidance. Inspected the committed diffs plus the current
digest subsystem (`lib/hive/digest.rb`, `lib/hive/digest/**`,
`templates/digest_prompt.md.erb`, `lib/hive/cli.rb`,
`lib/hive/commands/digest.rb`, `lib/hive/daemon/digest_scheduler.rb`,
`lib/hive/config.rb`) and focused digest/CLI/daemon/config tests.

Documented the new `hive digest [--date YYYY-MM-DD] [--dry-run] [--json]`
command, the `Hive::Digest.run` pipeline, ship-time selection, agent
categorizer output contract, Telegram MarkdownV2 renderer/sender seam, global
digest config loading, daemon scheduling through `Hive::Daemon::DigestScheduler`,
the opt-in live digest E2E, and success-only unregistered `hive-digest` JSON
shape. Added [[commands/digest]] and [[modules/digest]], updated [[cli]],
[[commands]], [[commands/daemon]], [[modules/daemon]], [[modules/config]],
[[commands/bot]], [[templates]], [[testing]], and [[index]], and recorded the
remaining uncertainty in [[gaps]]: no checked-in artifact proves a delivered
real digest from a live agent/Telegram run. Page coverage count increased from
78 to 80. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/digest]]
- [[modules/digest]]
- [[cli]]
- [[commands]]
- [[commands/daemon]]
- [[modules/daemon]]
- [[modules/config]]
- [[commands/bot]]
- [[templates]]
- [[testing]]
- [[gaps]]
- [[index]]
