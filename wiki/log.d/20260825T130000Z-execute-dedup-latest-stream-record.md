# Execute observation deduplication compares only the latest stream record

- The `4-execute` reconciler's idempotency check (`already_recorded?`) scanned
  the entire journal history (`records.any?`) while projection consumers apply
  last-event-wins semantics.
- A re-transition back to a previously observed state — e.g. `ChangesPresent`
  flipping clean → dirty → dirty again at a constant HEAD — was field-identical
  to an older record, got dropped as "already recorded", and left a stale
  unsatisfied current condition that blocked the `execute_to_open_pr` gate.
- Deduplication now finds the most recent record of the same event stream
  (`event_type` + `attempt_id` + payload condition) and compares fields against
  that record only; unchanged re-observations still deduplicate.
- Regression: `test_retransition_to_previously_recorded_state_is_journaled_again`
  in `test/unit/conditions/reconcilers/execute_test.rb` reproduces the
  three-run dirty/clean/dirty sequence and asserts run 3 appends.

Uncertainty: none observed; focused suite and broad local checkpoint green on
this worktree.
