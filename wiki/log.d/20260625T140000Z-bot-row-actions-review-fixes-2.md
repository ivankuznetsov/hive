## bot - row-action review-fix pass 2 (model unification + fail-loud)

**Action:** Stage 6-review fix pass 2 over the [[modules/bot]] row-action work.

**Type design:**
- `RowActions::Resolution` drops the redundant `suppress` boolean; it is now
  derived from `kind == :suppressed` so a contradictory `(suppress: true,
  kind: :plan_waiting)` pair is no longer representable. Construction enforces
  exactly one primary action for a non-empty resolution (the
  `find(&:primary) || actions.first` fallback is gone).
- `RowActions::Action` now also requires a non-nil `callback` and a `verb` for
  the `:rerun` role (the only role whose label/hint is verb-derived).
- The `:run` role is collapsed into `:rerun`: one role for "paused stage,
  re-run the agent", with the Run/Re-run label and next-step hint derived from
  the `verb` (`develop` → "Re-run", `finalize`/`run` → "Run"). The label and
  hint live in `NotificationBuilders.rerun_label` / `Supervisor#rerun_hint`.

**Fail-loud:**
- `NotificationBuilders#needs_input` replaces its catch-all `else
  default_needs_input` with an explicit `:generic_needs_input` arm and raises
  on any other kind.
- `Supervisor#next_step_hint` raises on an unmapped primary role instead of
  silently degrading to the laptop hint; `button_coverage_test` now sweeps
  every representative row through it.
- `PlanApproval.rewrite_to_develop` accepts an already-`hive develop ...`
  command idempotently, so the bot's stale-Approve tap on a row that raced to
  `:complete` dispatches the valid develop (the `:complete` no-op branch is now
  reachable) instead of falling to handle's generic rescue. `approve_plan`
  gains a local `ArgumentError` rescue that distinguishes corrupt plan.md /
  malformed queued command from a malformed callback.

**Robustness:** per-row isolation in `NotificationDispatcher` now wraps the
WHOLE per-row body (suppress predicates + `fingerprint`, not just the build) and
both it and `Supervisor#status_action_button` widen to `rescue StandardError`,
so a `NoMethodError`/`TypeError` on a bad attrs/workflow value drops one row
rather than aborting the tick / keyboard.

**Dependency hygiene:** `row_actions.rb` now declares its
`require "hive/bot/notification_builders"` (the two modules are mutually
recursive at runtime; neither references the other at load time, so the cycle
is safe) — requiring `row_actions` alone no longer raises `NameError` on a
recovery row.

**Cleanups:** `keyboard_for_actions` maps actions→buttons once; the dead
`result_stage` `respond_to?(:stage)` guard and the unreachable
`status_action_emoji[:findings_reject]` / `[:run]` entries are gone.

**Tests:** `button_coverage_test` derives `WORKFLOWS` and `MARKERS` (incl.
`manual_steering`) from the closed registries; the review-triage keyboard pins
its un-flattened 2-wide row structure; the parity test annotates the
tautological brainstorm cell.

**New log event:** `callback_plan_state_corrupt` (added to `Logger::EVENTS` and
`schemas/hive-bot-log.v2.json`).

**Refreshed pages:**
- [[modules/bot]]
