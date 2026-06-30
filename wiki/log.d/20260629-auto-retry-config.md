---
title: Daemon auto-retry config
date: 2026-06-29
---

Added `daemon.auto_retry.enabled` as a global kill-switch for the daemon's health-probe-gated recoverable terminal-error auto-retry path. The key defaults to `true`, validates as a boolean under a mapping, and can be set to `false` to keep recoverable markers parked for manual `hive markers clear`. See [[commands/daemon]] and [[modules/config]].
