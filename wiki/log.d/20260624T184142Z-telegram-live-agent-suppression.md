## [2026-06-24T18:41:42Z] bot — suppress stale recovery markers during live retries

**Action:** `NotificationBuilders.build` now treats the live `action` as the
authoritative notification gate for `agent_running` and `archived` rows. If a
task lock makes status report `agent_running` while the state file still carries
a previous recovery marker such as `ERROR`, `REVIEW_ERROR`, `REVIEW_STALE`,
`REVIEW_CI_STALE`, or `EXECUTE_STALE`, the bot returns no notification and logs
`notification_skipped_live_agent` with project, slug, stage, marker, and action.
The event was added to `Hive::Bot::Logger::EVENTS` and the additive
`hive-bot-log.v2` enum.

`NotificationDispatcher` now also reads live `agent_running` identities from the
raw status rows before building notifications. Stored recovery alerts whose
project/slug/stage is currently live are held instead of being turned into a
premature "Recovered" message; if the retry fails the original stuck alert
dedupes, and if it succeeds the normal recovered confirmation fires after the
live identity disappears.

**Tests:** Added `notification_builders_test` coverage for the #9281
`agent_running` + `error` regression fixture, all stale recovery-marker
variants under `agent_running`, archived stale markers, unchanged `error` /
`recover_execute` / `recover_review` notifications, and suppression logging.
Added `notification_dispatcher_test` lifecycle coverage for live retry holds,
retry failure dedupe, and retry success recovery confirmation.
