---
title: Recoverable error healer
date: 2026-06-29
---

Added `Hive::Daemon::RecoverableErrorHealer`, a tick-time sibling to `StaleAgentHealer` that clears a fixed v1 allowlist of dependency-outage terminal errors only after safety checks, changed health-signal/backoff/budget gates, and health probes pass. It audits positive and skipped decisions to task events plus daemon logs, and `3-plan` clears enqueue a same-stage plan rerun through the dispatch-request queue. Dispatcher wiring runs it immediately after stale-agent healing and rebuilds it on SIGHUP reload. See [[modules/daemon]] and [[commands/daemon]].
