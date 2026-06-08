## [2026-06-08T11:34:30Z] wiki — audit daemon display-name backfill coverage

**Action:** Refreshed LLM wiki planning/documentation coverage after commit `9516efb1` added `Hive::Daemon::DisplayNameBackfiller` and already touched [[commands/daemon]], [[modules/daemon]], and a daemon feature log fragment. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "daemon display name backfill generate-name task display_name"` found existing task-identity coverage in [[state-model]] and prior [[log]] entries, and the configured master wiki path had no matching context. Inspected the committed diff plus current `lib/hive/daemon/display_name_backfiller.rb`, `lib/hive/daemon/dispatcher.rb`, `lib/hive/daemon/logger.rb`, focused daemon tests, and related display-name wiki pages.

**Action:** Updated task-identity documentation so [[state-model]], [[stages/inbox]], [[commands/new]], and [[commands/generate-name]] no longer imply missing display names are recovered only by the initial best-effort spawn, manual `hive generate-name`, or `hive migrate`; the daemon now retries blank sidecars cosmetically by spawning `hive generate-name <folder>` on later ticks. Refreshed [[commands/daemon]] and [[modules/daemon]] metadata for the new daemon module coverage, and recorded in [[gaps]] that the backfill path is unit-pinned but lacks an in-tree live daemon smoke artifact. Page count stayed 75, so [[index]] did not need a page-list update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/daemon]]
- [[modules/daemon]]
- [[state-model]]
- [[stages/inbox]]
- [[commands/new]]
- [[commands/generate-name]]
- [[gaps]]

## [2026-06-08T12:00:00Z] daemon — DisplayNameBackfiller inflight TTL + reap error logging

**Action:** Hardened `Hive::Daemon::DisplayNameBackfiller` reliability (PR #411 review follow-up). `@inflight` entries now store `{pid:, at:}` instead of a bare pid, and `reap_inflight(now)` evicts an entry when its child is gone (the existing `kill(0)`/ESRCH/EPERM liveness semantics are unchanged) **or** when it has outlived the new `MAX_INFLIGHT_AGE_SEC = 120` TTL (≈2× generate-name's 60s timeout). The TTL fixes a P1 bug: after the child was reaped, a reused pid could keep reporting "alive" (same-user `kill(0)` succeeds; foreign-user EPERM is also treated alive), permanently pinning the folder's inflight slot and disabling backfill for that folder until daemon restart. The TTL is threaded from `backfill(now:)` → `consider_row` → `backfill_row`, so live children within a single tick (age 0) are unaffected.

**Action:** The `reap_inflight` block-level `rescue StandardError` no longer swallows unexpected errors silently — it logs a `:fatal` event (`display_name_backfiller reap raised: ...`) before returning false (entry retained), matching the file's other rescues. Backfill still never raises.

**Action:** Brought `display_name_backfiller.rb` to 100% line coverage (was 84.72%, failing the strict coverage gate) and covered the dispatcher's backfiller `:fatal` rescue (dispatcher.rb line 239) by adding unit tests for: dead-pid reap (ESRCH), foreign-pid retention (EPERM), TTL eviction, reap-error logging, the outer `#backfill` rescue, unreadable-meta handling, injected-spawn raise, the real `Process.spawn` failure path, and the waiter-thread ECHILD rescue. See [[modules/daemon]].
