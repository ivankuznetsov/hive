---
title: Recoverable error healer review fixes
date: 2026-06-29
---

Review-pass hardening for `Hive::Daemon::RecoverableErrorHealer` and its collaborators:

- Extracted the marker-attr / match-attr / recovery-key / pre-clear-baseline-seeding / 3-plan-requeue cluster shared with `StaleAgentHealer` into `Hive::Daemon::HealerSupport` (mixed into both), so the anti-stranding baseline seed (now with a `marker_heal_observer_missing` log signal) and the `heal_requeue_failed` rescue can't drift between the two copies.
- Added the missing nil-`state_file_mtime` guard before the recoverable healer's marker clear (mirrors the sibling) and scoped post-clear bookkeeping out of the broad rescue so a successful clear is never relabeled `auto_retry_failed`.
- `doctor_probe` now fails closed: a `Hive::Commands::Doctor` config-error (EXIT_CONFIG_ERROR, nil rows) or any non-success exit no longer passes the universal health precondition.
- `AutoRetrySafety` fails closed for stages without a bespoke work-area check (plan R8), and its per-stage helpers are now private.
- Health fingerprints fold a stable error-class sentinel instead of raw exception messages, so transient noise can't re-arm retries; the probe/fingerprint first arg is renamed `category:` to match what the healer passes.
- Non-allowlisted reasons keep their daemon-log audit but no longer emit a task-timeline `auto_retry_skipped` event. Doc routing in [[modules/daemon]] corrected to match `Hive::Events::EVENT_TYPES`.

See [[modules/daemon]].
