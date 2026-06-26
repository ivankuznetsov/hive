## bot - row-action review-fix pass (type hardening + UX)

**Action:** Stage 6-review fix pass over the [[modules/bot]] row-action work.

**Type design:**
- `RowActions::Resolution` carries a `kind` tag (a closed `KINDS` set);
  `NotificationBuilders#needs_input` now dispatches on the kind instead of
  reverse-engineering the surface from the exact role array (which silently
  fell through to the neutral default on any reorder/extra action).
- `RowActions::Action` validates its `role` against a frozen `ROLES` set at
  construction (a typo'd/added role is now a boundary `ArgumentError`, not a
  deep `Hash#fetch` `KeyError`) and carries an explicit `verb` used by the
  status next-step hint (fixes the "tap Run to run run" copy → "run this
  stage"). `Resolution#primary` replaces the scattered
  `actions.find(&:primary) || actions.first`.
- `READY_ROLES` is gone; `ready_action?` derives from
  `NotificationBuilders.verb_for_action` as the single source of truth (every
  ready row's role is uniformly `:approve`).

**Robustness:** per-row build is isolated in `NotificationDispatcher`
(`build_notification`) and `Supervisor#status_action_button` so one malformed
row can't abort the whole tick / keyboard. `approve_plan` rescues
`SystemCallError`/`IOError` from the marker write with an actionable reply, and
documents the deliberate advance-then-resurface window. An unresolved `#`
compaction token now replies "button expired — reopen /queue" instead of "I
did not understand that".

**Cleanups:** dropped the dead `coding_stage?(row, "7-finalize")` disjunct and
the dead `waiting_input` builder / `actions: nil` fallbacks; added
`# coding-scoped:` annotations to the remaining stage literals; removed the
now-unreachable `--diagnose` slug inference; re-indented `finalize_action`.

**New log events:** `notification_build_failed`, `status_button_failed`,
`callback_marker_write_failed` (added to `Logger::EVENTS` and
`schemas/hive-bot-log.v2.json`).

**Refreshed pages:**
- [[modules/bot]]
