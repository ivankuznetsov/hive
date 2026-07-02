## [2026-07-01T23:58:03+01:00] daemon/web — post-commit wiki audit for arch-review-local-web-install

**Action:** Refreshed wiki planning/documentation coverage after branch `arch-review-local-web-install` committed its wiki refresh for the shared daemon-status producer. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "arch-review-local-web-install local web install daemon status unreadable setup web bundle"` returned no indexed hits, and the configured main wiki path had no relevant matches. Inspected the committed diff plus `git show` path reads for the branch's wiki fragment/gaps page, then checked current `lib/hive/daemon/status_report.rb`, `lib/hive/commands/daemon.rb`, `web/app/controllers/status_controller.rb`, `web/app/views/status/_daemon.html.erb`, `schemas/hive-daemon-status.v1.json`, and focused daemon tests.

Confirmed the main wiki already documents `Hive::Daemon::StatusReport` as the shared `hive-daemon-status` producer for CLI JSON and hivebox, including the web-safe `safe_payload` path and `StatusReport::BINARY_DRIFT_ACTIONABLE` repair-affordance enum. Carried forward the remaining uncertainty in [[gaps]]: source and tests cover source-level `binary_drift: "unreadable"`, but the published `hive-daemon-status` schema still omits that enum value, and no live daemon/web repair artifact was found. Page coverage stayed within existing pages, so [[index]] did not need a page-list update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[gaps]]
