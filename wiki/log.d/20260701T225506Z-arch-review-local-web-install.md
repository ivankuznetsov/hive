## [2026-07-01T23:55:06+01:00] daemon/web — refresh StatusReport command and API coverage

**Action:** Refreshed command/API and web route coverage after branch `arch-review-local-web-install` extracted the `hive-daemon-status` producer from `Hive::Commands::Daemon` into `Hive::Daemon::StatusReport`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "daemon status status_payload StatusReport binary_drift web dashboard"` returned no indexed hits, and the configured main wiki path had no relevant matches. Inspected the committed diff plus `lib/hive/daemon/status_report.rb`, `lib/hive/commands/daemon.rb`, `web/app/controllers/status_controller.rb`, `web/app/views/status/_daemon.html.erb`, `schemas/hive-daemon-status.v1.json`, and focused daemon tests.

Documented that `hive daemon status --json` and hivebox now share `Hive::Daemon::StatusReport`, with `safe_payload` as the web-safe in-process path and `StatusReport::BINARY_DRIFT_ACTIONABLE` as the web Repair affordance enum source. Updated the daemon command docs to include the source-level `unreadable` drift state. Narrowed the old unreadable-binary gap: source and tests now cover `unreadable`, but the published `hive-daemon-status` schema still omits it from the enum, so an actual unreadable payload is schema-unpinned. Page coverage count stayed the same, so [[index]] did not need a page-list update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/daemon]]
- [[commands/web]]
- [[modules/daemon]]
- [[testing]]
- [[gaps]]
