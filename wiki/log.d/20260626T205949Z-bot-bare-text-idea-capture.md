## bot — bare text defaults to idea capture

**Action:** Telegram router fallthrough now routes bare non-slash text outside
answer mode to the existing `/idea` capture path, so sending ordinary text opens
the project picker and records the text as the draft idea. Unknown slash
commands remain on the `:unknown` path, while answer conversations,
reply-to reattach, voice notes, media, and awaiting-text drafts keep their
existing higher-priority routes. Updated [[commands/bot]] and [[modules/bot]]
to remove the stale "free text is rejected" behavior.

**Tests:** Added router coverage for bare, one-character, forwarded-style, and
blank text; unknown slash commands; no-project capture; and the rejected-media
phantom-draft regression under the new default. Answer-mode priority over the
new bare-text idea default is not a new test — the no-draft path is pinned by
existing coverage (`test_free_text_inside_active_conversation_writes_current_question`
and `test_free_text_reply_can_reattach_to_slug_after_restart`), while
`test_idea_text_capture_does_not_hijack_active_brainstorm_conversation` guards
the answer-vs-`awaiting_text` precedence (it opens an `awaiting_text` draft
first). The S4 idea integration scenario now starts from bare text.
