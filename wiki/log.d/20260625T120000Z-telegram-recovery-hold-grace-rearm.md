## [2026-06-25T12:00:00Z] bot — re-arm recovery grace during a live-retry hold (A5)

**Action:** Corrected a false-recovered hazard in
`NotificationDispatcher#process_recoveries`. The live-identity hold is now
checked BEFORE the absence-grace window, and each held tick re-arms the grace
clock (`AlertStore#mark_present`, clearing `absent_since`). Previously grace was
checked first and could fully elapse *during* the hold, so the first tick the
`agent_running` identity was merely absent from the snapshot released the hold
and fired "✅ Recovered" — even when the retry had not finished. A per-project
status degrade (`commands/status.rb` keeps top-level `ok:true` while emptying a
project whose dir check fails; `status_watcher`'s `extract_rows` skips a project
with an `error`; the supervisor still calls `process_rows` because `result.ok`)
can drop a still-running row from a single tick, which is exactly the blip that
used to leak a premature Recovered. Recovered now fires only once the lock has
been gone for a full grace window after the hold genuinely lifts.

**Supersedes:** the earlier
`20260624T184142Z-telegram-live-agent-suppression` note's "`absent_since`
continuity during a hold" property — `absent_since` is now deliberately
re-armed (kept un-started) while held, not carried across the hold.

**Tests:** Replaced the absent_since-continuity test with
`test_grace_clock_is_rearmed_every_tick_while_live_retry_holds_the_row`; added
`test_mid_hold_single_tick_identity_drop_does_not_fire_premature_recovered`
(transient one-tick degrade keeps the hold, no Recovered, entry retained),
`test_clean_agent_working_retry_holds_recovery_independent_of_marker`
(marker-independent hold: `agent_running` + `agent_working`), and
`test_live_agent_for_different_project_does_not_hold_same_slug_recovery`
(project component of `recovery_identity`). The live-retry resolution tests now
advance past the post-hold settling window, and the archived / manual_steering
recovery tests pin an exact `RECOVERED_MESSAGE` body and total message count.
The builders archived-error test now asserts `:notification_skipped_live_agent`
fires with `action: "archived"`.
