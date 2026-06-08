## [2026-06-08T11:54:15Z] wiki — audit daemon display-name backfill TTL coverage

**Action:** Refreshed LLM wiki planning/documentation coverage after commit `a0b0ca3b` bounded `Hive::Daemon::DisplayNameBackfiller` inflight entries and expanded unit coverage. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "daemon display name backfill generate-name meta.yml"` returned no indexed hits, and the configured master wiki path had no matching context. Inspected the committed diff plus current `lib/hive/daemon/display_name_backfiller.rb`, `lib/hive/daemon/dispatcher.rb`, `lib/hive/daemon/logger.rb`, `test/unit/daemon/display_name_backfiller_test.rb`, `test/unit/daemon/dispatcher_test.rb`, and related display-name/task-identity wiki pages.

**Action:** Updated [[modules/daemon]], [[commands/daemon]], and [[commands/generate-name]] so the durable docs describe the new `{pid, at}` inflight shape, `MAX_INFLIGHT_AGE_SEC = 120` retry unpinning behavior, and `:fatal` logging for unexpected backfiller failures. Updated [[gaps]] to carry the new test-pinned reliability coverage while keeping the live-smoke uncertainty open: no in-tree artifact yet proves a real daemon backfilled an existing blank `meta.yml` name and surfaced it through status/TUI/bot. Page count stayed 75, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/daemon]]
- [[commands/daemon]]
- [[commands/generate-name]]
- [[gaps]]
