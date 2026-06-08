## [2026-06-08T11:51:13Z] wiki — audit bot draft-confirm residue cleanup

**Action:** Refreshed command/API and handler wiki coverage after commit `c680ac29` removed dead Telegram bot confirm/draft residue left behind by the Codex draft-assist retirement. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "CodexConversation confirm draft residue conversation_store path_a bot codex draft assist"` returned no indexed hits, and the configured master wiki path had no relevant draft-assist context. Inspected the committed diff plus current `lib/hive/bot/conversation_store.rb`, `lib/hive/bot/router.rb`, `lib/hive/bot/handlers/free_text_handler.rb`, `lib/hive/bot/handlers/callback_handlers.rb`, `lib/hive/bot/handlers/slash_handlers.rb`, and focused bot tests.

Documented that `ConversationStore::State` now carries only the active answer context (`chat_id`, `project`, `slug`, `question_n`, `mode`, `updated_at`), with no `history`, `draft`, `awaiting_confirm`, or `pending_confirm_count` API; that `/done` clears and dispatches the active conversation directly with no draft-confirm guard; that Path A/B is compatibility-only and both modes route through `write_answer_then_reply`; and that legacy Path-A buttons degrade to the deterministic `/answer` instructions while retired `codex_*` callback data remains unknown. Carried forward the live-smoke uncertainty for old Telegram buttons, live `:path_a` answer writes, and installed `hive-bot-log.v2` consumers. Page coverage count stayed 75, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/bot]]
- [[modules/bot]]
- [[state-model]]
- [[gaps]]
