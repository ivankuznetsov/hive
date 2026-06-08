## [2026-06-08T12:49:08Z] bot, daemon — tolerate hive-status schema_version skew instead of crashing

**Action:** Made both long-running `hive-status` consumers forward-tolerant of a `schema_version` skew instead of raising a raw `ArgumentError`. Root cause: `Hive::Bot::StatusWatcher#validate_envelope!` and `Hive::Daemon::StatusConsumer#validate_envelope!` enforced an EXACT match against the in-memory `Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status")`. When the gem is updated (schema bumped) but the bot/daemon process is NOT restarted, the in-memory `expected` is stale while the `hive status --json` subprocess emits the newer version, so the consumer hard-failed. In production this surfaced as the Telegram bot replying `hive status unavailable: ArgumentError: schema_version mismatch: got 3, want 2` to every `/status` until restart.

Fix: `validate_envelope!` now enforces only the envelope SHAPE (missing/wrong `schema`, `ok=false`) as a hard error. Version skew is classified by a new `schema_skew(doc)` → `:match` / `:newer` / `:older`. `:newer` (updated binary, additive envelope) parses best-effort and logs a one-line skew warning (bot: `poll_failure`; daemon: new closed-enum `:status_schema_skew` event surfaced via a new non-fatal `Result#warning` the dispatcher logs once per tick); if best-effort extraction throws, it degrades to an actionable `… is newer than this process (vM); restart the hive bot/daemon to pick up the new version`. `:older` (stale binary on PATH) returns an actionable `… is older than this process (vM); update/reinstall the hive binary on PATH`. `:match` is the unchanged happy path. The contract: a long-running consumer never crashes `/status` (or a daemon tick) with a raw `ArgumentError` purely because a schema_version was bumped without a restart.

`Hive::Bot::Supervisor#diagnose_reply_for_child` consumes the sibling `hive-status-diagnose` envelope but only checks `schema == ...` (never `schema_version`), so it did NOT share the brittleness and was left out of scope.

Tests: extended `status_watcher_test.rb` (+3) and `status_consumer_test.rb` (replaced the old mismatch test with +3) to prove newer = best-effort parse/warning, older = actionable failure, exact = unchanged, and that envelope-shape errors still hard-fail; added a dispatcher test proving a forward-skew result still dispatches and logs `:status_schema_skew`.

**Refreshed pages:**
- [[modules/daemon]]
- [[commands/bot]]
