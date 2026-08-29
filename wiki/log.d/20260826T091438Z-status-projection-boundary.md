# 2026-08-26 — One internal status projection boundary

## Summary

Introduced `Hive::StatusProjection` (`lib/hive/status_projection.rb`) as the
single internal boundary that owns status presentation ordering and
archive-aware payload composition. `Commands::Status` re-exports the frozen
`ACTION_LABEL_ORDER` from the boundary instead of defining it inline;
`Tui::Snapshot` orders rows via `Hive::StatusProjection.label_position`
instead of reaching into `Hive::Commands::Status::ACTION_LABEL_ORDER`; and
`Tui::StateSource` no longer implements its own second layer of payload
interpretation — `archive_payload_from_cache` and
`merge_visible_archived_payload` moved verbatim onto the projection boundary.

## Details

- Patrol finding: make-status-projection-boundary-authoritative
  (TUI data boundary reached into the command boundary for presentation
  ordering and rebuilt/merged archive payloads outside both Status and
  Snapshot).
- Behavior is unchanged: same frozen label order (unknown labels last,
  payload order preserved as tie-break), same error-project degradation and
  hidden-count restating in both archive cache modes, inputs still never
  mutated.
- Regression coverage: new `test/unit/status_projection_test.rb` pins the
  ordering semantics, both composition helpers, input immutability, the
  command's re-export identity (`assert_same`), and a source-level check
  that `Tui::Snapshot` no longer references `Commands::Status::` and that
  StateSource defines no local reconstruction methods. Existing
  state_source tests now call the boundary directly.

## Validation

- `bundle exec ruby -Itest test/unit/status_projection_test.rb`
- `bundle exec ruby -Itest test/unit/tui/snapshot_test.rb`
- `bundle exec ruby -Itest test/unit/tui/state_source_test.rb`
- `bundle exec ruby -Itest test/unit/tui/schema_correspondence_test.rb`
- `bundle exec ruby -Itest test/unit/tui/views/tasks_pane_test.rb`
- `bundle exec ruby -Itest test/unit/commands/status_test.rb`
- `bundle exec ruby -Itest test/integration/archive_visibility_retention_test.rb`
- `bundle exec ruby -Itest test/integration/status_test.rb`
- Rubocop clean on all touched files.
