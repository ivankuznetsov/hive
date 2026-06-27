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
phantom-draft regression under the new default. Answer-mode priority is not a
new test — it relies on existing answer-mode-priority coverage
(`test_idea_text_capture_does_not_hijack_active_brainstorm_conversation`). The
S4 idea integration scenario now starts from bare text.
