---
title: Recoverable error healer routing refresh
date: 2026-06-29
---

Refreshed LLM wiki coverage for branch `make-the-hive-daemon-automatically-260629-223d` after its docs-only review fix corrected recoverable auto-retry event-channel routing.

Verified the committed wiki diff against current source and tests: `Hive::Events::EVENT_TYPES` only allows task-local `auto_retry` / `auto_retry_skipped`, while `Hive::Daemon::Logger::EVENTS` allows the broader daemon-log audit set (`auto_retry`, `auto_retry_skipped`, `auto_retry_exhausted`, `auto_retry_failed`). `RecoverableErrorHealer` suppresses task events for non-allowlisted reasons, maps exhausted retries to task `auto_retry_skipped`, keeps all four names in the daemon log, guards nil `state_file_mtime` before clears, and lets `HealerSupport#requeue_plan_rerun` log `heal_requeue_failed` after a successful clear without relabeling the clear as `auto_retry_failed`.

Updated [[modules/daemon]] because the main wiki still lacked the recoverable-healer module row and tick-order placement, and added [[gaps]] uncertainty for the missing live-daemon smoke of the Codex-auth / Claude-launch recoverable auto-retry path. No page was created, so [[index]] page coverage did not change.
