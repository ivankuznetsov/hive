# ConversationStore: one active answer conversation per chat

Date: 2026-08-22
Scope: `lib/hive/bot/conversation_store.rb`

## What changed

`ConversationStore#start` now supersedes: before inserting the new state for
`(chat_id, slug)`, it deletes every other stored entry whose key has the same
`chat_id`. Previously each `(chat_id, slug)` pair kept its own entry, so
starting `/answer task-b` while `task-a` was still open left both entries in
the store. The slug-less lookup `get(chat_id:)` (used by `FreeTextHandler`,
`Router#answer_context`, and slash `/done`) then returned whichever slug had
been started first — the next free-text reply after opening task B was written
to task A.

## Why

Consumers model a chat as having exactly one active answer target; only the
store modeled identity as chat plus slug. Making `start` enforce the single-
active-conversation invariant at the root keeps every unscoped consumer
correct without changing their call sites.

## Tests

- `test/unit/bot/conversation_store_test.rb`: supersede regression (second
  start wins, old entry removed, other chats untouched).
- `test/unit/bot/free_text_handler_test.rb`: end-to-end guard that a free-text
  reply after opening a second conversation routes to the newest slug.
