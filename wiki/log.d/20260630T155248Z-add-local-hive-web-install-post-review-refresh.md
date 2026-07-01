## [2026-06-30T15:52:48Z] setup/web/daemon — residual wiki coverage audit

**Action:** Refreshed wiki planning/documentation coverage after branch `add-local-hive-web-install-260629-f4ca` produced a residual 6-review wiki-only commit. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent [[log]] entries, ran `qmd search "local setup web install daemon status binary drift unreadable"` (no hits), checked the configured main wiki path, inspected the committed diff and committed wiki pages via `git show`, and rechecked current source/tests for `Hive::Commands::Setup`, `Hive::Commands::Web`, `Hive::Web::AppBundle`, `Hive::Commands::Daemon`, `schemas/hive-daemon-status.v1.json`, and related unit coverage.

**Coverage:** Kept the main-checkout wiki pages as the canonical coverage because they are already more complete than the residual committed `commands/setup` page and include the current local setup, managed web-bundle, same-binary service install, loopback auth, daemon-status, and test coverage details. Updated [[gaps]] only to record that this residual refresh did not close the missing live local-install smoke evidence and did not resolve the `binary_drift: unreadable` daemon-status schema/test uncertainty. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[gaps]]
