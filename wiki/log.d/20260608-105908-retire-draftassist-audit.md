## [2026-06-08T10:59:08Z] wiki — audit retired bot Codex draft-assist coverage

**Action:** Refreshed command/API, handler, config, schema, template, and executable-entrypoint wiki coverage after commit `723906be` retired the Telegram bot's Codex draft-assist flow. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "bot codex draft assist path a answer log schema"` found only older generic bot command context, and the configured master wiki path had no matching draft-assist context. Inspected the committed diff plus current `lib/hive/bot/router.rb`, `lib/hive/bot/handlers/callback_handlers.rb`, `lib/hive/bot/handlers/free_text_handler.rb`, `lib/hive/bot/logger.rb`, `lib/hive/config.rb`, `schemas/hive-bot-log.v2.json`, `templates/hive_config.yml.erb`, and focused bot/config/logger tests.

Confirmed the committed [[architecture]], [[commands/bot]], [[modules/bot]], [[state-model]], and [[templates]] updates match the current code: brainstorm answering is deterministic for Path A and Path B, `Hive::Bot::CodexConversation` and its prompt template are gone, retired `codex_*` callback-data no longer parses to a live intent, the bot config no longer exposes Codex budget/timeout knobs, and `hive-bot-log.v2` removes the three Codex events while preserving `hive-bot-log.v1` for historical lines. Added [[gaps]] coverage for the remaining uncertainty: source-tree tests pin the behavior, but no in-tree live Telegram artifact proves old Path-A buttons, retired Codex callback-data, deterministic live `:path_a` answer writes, or installed log consumers against `hive-bot-log.v2`. Page coverage count stayed 75, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[architecture]]
- [[commands/bot]]
- [[modules/bot]]
- [[state-model]]
- [[templates]]
- [[gaps]]
- [[log]]
