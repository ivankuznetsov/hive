## task-action - U4 review-pass 3 coverage + doc-formatting fixes

**Action:** Closed review-pass-3 test-coverage gaps and one doc-rendering bug for
the descriptor-generic classifier; no production behavior changed:
- Pinned the daemon-decision outcome of the markerless **inert entry** `:none` ->
  `ready_to_advance` row (`test_generic_inert_entry_none_dispatches_at_policy_decision_level`).
  This is the only generic path that auto-advances a stage with zero prior
  execution; the matrix test asserted its classification key but never ran a
  `policy_decision` on it, so a regression dropping `ready_to_advance` from
  `ADVANCE_ACTIONS` or widening the `:none` guard to non-entry stages would have
  stayed green.
- Pinned the generic stale-agent **orphaned-placeholder** branch
  (`test_generic_stale_agent_orphaned_placeholder_classifies_as_error`): a no-pid
  `AGENT_WORKING` marker past the grace window classifies as `:agent_orphaned` ->
  error, completing plan IU-4's "stale ⇒ error" coverage (the matrix test only
  covered the `pid_alive:false` / agent_died half).
- Pinned `ACTION_LABEL_ORDER` generic-label placement
  (`test_action_labels_sorts_generic_labels_above_error`): both "Ready to run" and
  "Ready to advance" must sort above "Error" via the live `action_labels` sorter,
  so dropping either entry can no longer silently sink generic rows below "Error".
- Fixed the `[[modules/task_action]]` action-map table: the `generic_ready_to_run`
  wire-format prose had been inserted mid-table, breaking the `agent_running` /
  `done` / `error` rows; moved it below the `error` row so the whole table renders.
- Flagged a forward-looking U5 gap in `wiki/gaps.md`: generic workflows have no
  dedicated stale/error resting-marker surface (the `generic_action` `else` arm
  classifies any unknown resting marker as "Ready to run" with no diagnostic).

**Verification:** `bundle exec ruby -Itest test/unit/task_action_generic_test.rb`
(15 runs), `test/unit/commands/status_test.rb`, `test/unit/daemon/policy_test.rb`,
`test/unit/schema_files_test.rb`, plus the TUI snapshot/tasks-pane suites that
consume `ACTION_LABEL_ORDER`; rubocop clean on the edited test files. The
requested Ruby↔JSON enum-parity test was already present
(`test_hive_status_task_enums_match_closed_sets` and
`test_hive_stage_action_next_action_key_enum_matches_task_action_kind` in
`schema_files_test.rb`), so no duplicate was added.

**Pages:** [[modules/task_action]], [[commands/status]], [[gaps]]
