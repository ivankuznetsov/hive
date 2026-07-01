---
title: Recoverable error healer fingerprint per-tick cache and scoping note
date: 2026-06-30
---

Follow-up review-pass fixes for `Hive::Daemon::RecoverableErrorHealer`:

- The `HealthSignal` fingerprint is row-independent (it depends only on category/config/env), so the healer now memoizes it once per category per tick (`tick_fingerprint`, reset at the top of each `heal`). Previously the fingerprint — the *input* to the changed-signal gate — re-ran `claude --version` plus an in-process `hive doctor` for every parked row on every tick, defeating the gate it feeds.
- Documented the intentional v1 scoping limitation in [[modules/daemon]]: the health gate uses `project_root: nil` + daemon-global config, so it ignores a parked task's per-project config/reviewer inventory/agent overrides. Acceptable because the v1 allowlist (Codex auth, Claude launcher) covers global-CLI dependency outages and the blast radius is bounded; per-project scoping is deferred to the allowlist-expansion follow-up.

See [[modules/daemon]].
