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
`agent_running` + `error` regression fixture, the parameterized recovery
markers under `agent_running` (`review_stale`, `execute_stale`, `review_error`,
`review_ci_stale`; the `error` marker is covered by its own case), an archived
`error` row, unchanged `error` / `recover_execute` / `recover_review`
notifications, and suppression logging. Added `notification_dispatcher_test`
lifecycle coverage for live retry holds, retry failure dedupe, retry success
recovery confirmation, the cross-layer agent_running contract (builder suppress
+ dispatcher hold), identity-scoped holds (a different slug does not hold an
unrelated recovery), the archived-vs-agent_running asymmetry (archived can fire
Recovered), `absent_since` continuity during a hold, and skip-event logging
across the held retry lifecycle.
