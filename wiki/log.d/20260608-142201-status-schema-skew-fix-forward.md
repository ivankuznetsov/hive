## [2026-06-08T14:22:01Z] bot, daemon — fix-forward on #416: don't mask real errors behind the schema-skew degrade; surface skew in bot /status

**Action:** Fix-forward on #416 (commit 8b1cf115) addressing pr-review-toolkit findings on the `hive-status` forward-skew handling in `Hive::Bot::StatusWatcher#fetch` and `Hive::Daemon::StatusConsumer#fetch`.

**Findings fixed:**

1. **(CRITICAL) The `:newer` rescue over-swallowed and discarded the real error.** The single broad `rescue StandardError` keyed the "just restart" message off `schema_skew(doc) == :newer` alone and threw away `e`. Two consequences: (a) a genuine bug in `extract_rows`/`extract_projects`/`extract_legacy_stage_dirs` on a newer doc got relabeled "restart to pick up the new version" (operator restarts → same bug → defect stays invisible); (b) `validate_envelope!`'s own `ArgumentError` ("envelope ok=false: …" / "missing schema") is a `StandardError` too, so on a `:newer` doc it ALSO degraded to the skew message, masking the real `ok=false` reason. **Fix:** both `#fetch` methods now run `validate_envelope!` OUTSIDE the degrade, and wrap ONLY the extraction phase in its own `begin/rescue`. That inner rescue `raise unless skew == :newer` (an exact/equal-version extraction throw re-raises to surface the raw `#{e.class}: …`); when it does degrade, the surfaced message PRESERVES the underlying exception (`… (underlying error: <Class>: <msg>)`). The bot also logs the underlying error (class + message + first 3 backtrace lines) under `:poll_schema_skew`. Existing `JSON::ParserError` handling kept before the broad rescue.

2. **(HIGH) Bot `/status` showed degraded data with NO indicator.** Added a `warning` field to the bot `StatusWatcher::Result` (mirrors the daemon Result), populated on the `:newer` best-effort success path. `Supervisor#execute_dispatch` prepends a plain-text banner ("⚠️ hive status: running on a newer schema than this bot understands; data may be incomplete — restart the bot.") when the fetch carries a warning (via `status_fetch_warning`, tolerant of older Result shapes like `status_legacy_stage_dirs`).

3. **(MEDIUM) Forward-skew advisory was logged under `:poll_failure` (overloaded).** The bot's `warn_forward_skew` (and the new underlying-error log) now use a distinct `:poll_schema_skew` event. Added `poll_schema_skew` to `Hive::Bot::Logger::EVENTS` and to the `hive-bot-log.v2` schema `event` enum (additive append — no SCHEMA_VERSION bump). The daemon already used a distinct `:status_schema_skew`.

4. **(LOW) KeyError-in-rescue fragility.** The bot's `schema_skew`/`forward_skew_summary`/`older_skew_message` used `SCHEMA_VERSIONS.fetch("hive-status")`, which would raise `KeyError` inside a rescue-reachable path if the key were absent. Replaced with a memoized `expected_schema_version` using the non-raising `["hive-status"]` form, computed once and reused (mirrors the daemon, which already used `[]`).

**Deferred (not implemented):** per-tick / per-poll log dedup of the skew advisory — currently it can log once per tick/poll while the skew persists. Noted as a follow-up enhancement.

**Tests:** `status_watcher_test.rb` and `status_consumer_test.rb` extended — a `:newer` + `ok=false` envelope returns the REAL ok=false message (not the skew hint); a `:newer` extraction throw returns a message containing BOTH the restart hint AND the underlying `e.class: e.message` and logs the real error (bot), result `ok:false`, never raises; an exact-version extraction throw surfaces the raw error (not the skew hint). Bot: `:newer` best-effort success sets `Result#warning`; supervisor render prepends the banner (and omits it when clean). `:poll_schema_skew` fires on the bot success-path skew. The `hive-bot-log` logger test (whitelist scan + schema-valid emit) covers the new event. Full coverage gate green at 100.0% (changed files all 100%).

**Refreshed pages:**
- [[modules/bot]]
- [[modules/daemon]]
