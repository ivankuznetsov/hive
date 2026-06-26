## [2026-06-25T09:56:20Z] bot - noise category is a downstream-only convention

**Action:** Clarified that the bot log `noise` category is a **downstream-only**
convention — producers tag high-frequency, low-signal lines (benign poll-transport
failures, dedupe/backoff skips) with it, but nothing in the gem filters on it; an
external log viewer/forwarder is expected to drop `category=noise` lines. Extracted
the one load-bearing value as `Hive::Bot::Logger::CATEGORY_NOISE` so the single
significant category is greppable while the `category` field stays open-set, and
used it at the three producer sites (`Telegram`, `NotificationDispatcher` ×2).
Reworded the overclaiming `logger.rb` comment, documented the contract in the
`hive-bot-log.v3` schema `category` description, and scoped `PollHealth::Result`'s
`consecutive_failures` / `seconds_since_success` to the escalation path with a doc
comment.

**Tests:** Pinned `LEVELS.keys ⊆ EVENTS` (catches a stale/misspelled LEVELS key
silently ignored by `LEVELS.fetch`), pinned a strict bijection between the
`hive-bot-log.v3` event enum and `Logger::EVENTS` (catches schema-side drift),
pinned that `build_update` parse failures never escalate poll-health even past
`max_consecutive`, and pinned that a second backoff episode for a fingerprint that
never leaves `current` stays log-suppressed (the deliberate in-memory-Set tradeoff,
asserted `== 1`).

**Refreshed pages:**
- [[modules/bot]]
