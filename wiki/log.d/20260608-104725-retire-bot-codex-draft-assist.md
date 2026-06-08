## [2026-06-08T10:47:25Z] bot — retire Codex draft-assist feature

**Action:** Removed the Telegram bot's "Codex draft-assist" flow (the Path-A mobile-brainstorm path where the bot spawned Codex to draft an answer to a brainstorm question, offering write-draft / edit / cancel buttons). Brainstorm answering is now deterministic Q-by-Q for every conversation mode: the operator's reply is written verbatim into the next unanswered `brainstorm.md` slot and the bot sends the next question.

Specifically:
- Deleted `lib/hive/bot/codex_conversation.rb` (`Hive::Bot::CodexConversation`) and its prompt template `templates/bot_brainstorm_codex_prompt.md.erb`.
- Bumped `Hive::Bot::Logger::SCHEMA_VERSION` 1 → 2 and dropped the `codex_spawned` / `codex_succeeded` / `codex_failed` events from `EVENTS`.
- Added `schemas/hive-bot-log.v2.json` (event enum minus the three codex_* events, `schema_version` const 2). `schemas/hive-bot-log.v1.json` is kept as-is for historical log lines.
- Removed the `codex_budget_usd` / `codex_timeout_sec` bot defaults and their `BOT_NUMERIC_BOUNDS` entries from `lib/hive/config.rb`, and the matching commented lines in `templates/hive_config.yml.erb`.
- Removed the `callback_codex_write_draft` / `callback_codex_edit` / `callback_codex_cancel` intents, the `codex_write:` / `codex_edit:` / `codex_cancel:` callback parsing, and the `start_codex` / `confirm_codex_draft` allowed-actions from `lib/hive/bot/router.rb`. Retired callback-data now classifies as `:unknown`.
- Dropped the three codex callbacks from the legacy retirement-notice branch in `lib/hive/bot/handlers/callback_handlers.rb` (the Path-A `path_a_yes` / `path_a_just_type` legacy fallback is kept and still returns the "Codex draft flow was removed" steer).
- Removed the `action: :start_codex` branch from `lib/hive/bot/handlers/free_text_handler.rb`; a `:path_a` conversation now falls through to the same deterministic `write_answer_then_reply` path as `:path_b`.

**Kept (correctness guardrail):** The `"Answer mode started for <slug>."` reply-reattach matcher in `router.rb` and `free_text_handler.rb` is part of the GENERAL answer-mode reply flow — it lets a free-text reply to an old bot message reattach to that slug's brainstorm answer flow (`mode: :path_b`) and is independent of Codex. The text is not Codex-specific and is not sent by any removed code path, so it was retained.

**Tests:** Deleted `test/unit/bot/codex_conversation_test.rb`. Updated `callback_handlers_test.rb`, `router_test.rb`, `supervisor_test.rb`, `config_test.rb`, `spawn_agent_test.rb`, `logger_test.rb` (now validates against `hive-bot-log.v2.json` and asserts `schema_version == 2`), and eval support `reason_classifier.rb` / `harness.rb` — removed draft-assist intents/fixtures/config while preserving coverage for everything that remains. Suite green.

**Refreshed pages:**
- [[architecture]]
- [[state-model]]
- [[templates]]
- [[modules/bot]]
- [[commands/bot]]
