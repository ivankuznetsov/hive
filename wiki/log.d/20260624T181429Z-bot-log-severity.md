## [2026-06-24T18:14:29Z] bot - structured bot log severity and noise controls

**Action:** Bumped `Hive::Bot::Logger` to `hive-bot-log.v3` with required
`level`, optional `category`, and the new `poll_unhealthy` event while keeping
`hive-bot-log.v1` and `hive-bot-log.v2` for historical lines. Added
`Hive::Bot::PollHealth` so benign Telegram long-poll transport failures remain
visible as `poll_failure` but at `debug`/`noise`, with a single loud
`poll_unhealthy` warning when the poll loop stays unhealthy. `NotificationDispatcher`
now emits `notification_skipped_dedupe` and `notification_skipped_backoff` only
when an active fingerprint enters that skip state, when its fingerprint changes,
or after it leaves and returns.

**Tests:** Added focused logger, poll-health, Telegram polling, and notification
dispatcher coverage for severity defaults, v2 back-compat, info-stream noise
filtering, benign-vs-real poll failures, once-per-outage escalation, and
transition-only skip logging.

**Refreshed pages:**
- [[modules/bot]]
- [[commands/bot]]
