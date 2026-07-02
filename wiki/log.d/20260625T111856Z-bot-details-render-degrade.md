## [2026-06-25T11:18:56Z] bot — soft-degrade the Show-details render path

**Action:** All three sites that render `NotificationBuilders.details_reply(row)` — inline `details:` callbacks (`CallbackHandlers#show_details`), `/details` (`SlashHandlers#details`), and `Supervisor#render_details` — now wrap the render in a soft-degrade rescue. A render-time fault logs the new `details_render_failed` event and replies "Status lookup failed — try again in a moment." instead of escaping past the already-ack'd callback / poll loop and leaving the operator with no reply (preserving the "never a dead end" guarantee). The slash `resolve_status_row` degrade now logs the new `status_lookup_failed` event, and `CallbackHandlers#resolve_details_row`'s degrade logs a backtrace. Both new events are registered in `Logger::EVENTS` and the `hive-bot-log.v2` schema enum (additive, no version bump). `Diagnostic` coerces its members to strings in `initialize` so `#text` can't `NoMethodError` on a nil member.

**Refreshed pages:**
- [[modules/bot]]
