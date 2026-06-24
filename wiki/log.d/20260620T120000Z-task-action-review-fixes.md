## task-action - U4 review-pass accuracy/clarity fixes

**Action:** Tightened the descriptor-generic classifier docs and guards after
review pass 2:
- Reworded the `:none` entry fall-through (code comment + `[[modules/task_action]]`)
  from the `:agent`-only understatement to "any non-inert entry kind" — the gate
  is `stage.kind == :inert`, which excludes `:agent`, `:marker`, and `nil`.
- Documented the deliberate lossy merge: `generic_ready_to_run` and
  `generic_needs_input` share the `NEEDS_INPUT` key + `run` command, so the
  run-vs-input distinction survives only in the label, not on the JSON wire
  (intended per plan R3/Q2; daemon routing uses the mtime baseline, not the key).
- Recorded the U5-deferred behavior in code: a markerless generic stage stays at
  `:record_baseline` until a human edits the state file (no auto-dispatch yet).
- Added `"Ready to run"` and `"Ready to advance"` to `ACTION_LABEL_ORDER` in
  `Hive::Commands::Status` so generic rows sort with the actionable rows instead
  of below `"Error"`.

**Verification:** `bundle exec ruby -Itest test/unit/task_action_generic_test.rb`
plus the new `agent_entry_workflow` fixture that discriminates the `entry` and
`stage.kind == :inert` conjuncts of the `:none` advance guard in isolation.

**Pages:** [[modules/task_action]], [[commands/status]]
