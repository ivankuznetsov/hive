---
date: 2026-06-12
slug: web-recovery-button
pages: [commands/web]
---

Operator-reported: a "Needs recovery" task (reviewer died on claude token
limits) had no recovery affordance on its web page. Task pages now show a
red diagnostic banner (the row's diagnostic.summary — WHY it is red, not
just that it is) and a "Retry stage" primary button for the three
diagnostic actions (recover_review/recover_execute/error).
`Web::Dispatcher#recover` reuses the bot's
`Handlers::RecoverySequence` verbatim — manual-only guard, guarded
`hive markers clear --match-attr`, then the stage verb — written to the
daemon queue as one request sequence (the retry stays invisible until the
clear exits 0), trigger=web_recover. Web, bot, and TUI now recover
byte-identically. Live-verified by recovering the real stuck review.
