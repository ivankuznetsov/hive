require "test_helper"
require "hive/tui/model"
require "hive/tui/snapshot"
require "hive/tui/views/grid"

# Pin layout/text content of `Views::Grid.render(model)`. Lipgloss strips
# ANSI when stdout is not a tty (U2 finding), so these tests assert the
# visible characters and structural lines — not the escape sequences.
# Visual styling is validated by manual dogfood per R19.
class HiveTuiViewsGridTest < Minitest::Test
  include HiveTestHelper

  def base_model(snapshot:, **overrides)
    Hive::Tui::Model.initial.with(snapshot: snapshot, cols: 80, rows: 24, **overrides)
  end

  def snapshot_with(projects)
    Hive::Tui::Snapshot.new(generated_at: "2026-04-27T12:34:56Z", projects: projects)
  end

  def project(name:, rows:, error: nil)
    Hive::Tui::Snapshot::ProjectView.new(
      name: name, path: "/x", hive_state_path: "/x/.hive", error: error, rows: rows.freeze
    ).freeze
  end

  def row(slug:, action_key: "ready_to_brainstorm", action_label: "ready to brainstorm",
          suggested_command: "hive brainstorm #{slug}", age_seconds: 30,
          claude_pid: nil, claude_pid_alive: nil, project_name: "demo")
    Hive::Tui::Snapshot::Row.new(
      project_name: project_name, stage: "1-input", slug: slug, folder: nil,
      state_file: nil, marker: nil, attrs: nil, mtime: nil, age_seconds: age_seconds,
      claude_pid: claude_pid, claude_pid_alive: claude_pid_alive,
      action_key: action_key, action_label: action_label,
      suggested_command: suggested_command
    ).freeze
  end

  # ---- Header ----

  def test_header_includes_scope_filter_generated_at
    snap = snapshot_with([])
    model = base_model(snapshot: snap)
    out = Hive::Tui::Views::Grid.render(model)
    assert_includes out, "hive tui"
    assert_includes out, "scope=all"
    assert_includes out, "filter=-"
    assert_includes out, "generated_at=2026-04-27T12:34:56Z"
  end

  def test_header_with_scope_and_filter_set
    snap = snapshot_with([])
    model = base_model(snapshot: snap, scope: 2, filter: "auth")
    out = Hive::Tui::Views::Grid.render(model)
    assert_includes out, "scope=2"
    assert_includes out, "filter=auth"
  end

  def test_header_falls_back_when_snapshot_nil
    model = base_model(snapshot: nil)
    out = Hive::Tui::Views::Grid.render(model)
    assert_includes out, "generated_at=-"
  end

  # ---- Stalled banner (last_error) ----

  def test_stalled_banner_renders_when_last_error_set
    snap = snapshot_with([])
    err = StandardError.new("boom")
    model = base_model(snapshot: snap, last_error: err)
    out = Hive::Tui::Views::Grid.render(model)
    assert_includes out, "[stalled — StandardError]"
  end

  def test_no_stalled_banner_when_last_error_nil
    snap = snapshot_with([])
    model = base_model(snapshot: snap)
    out = Hive::Tui::Views::Grid.render(model)
    refute_includes out, "stalled"
  end

  # ---- Empty registry ----

  def test_empty_registry_shows_centered_init_message
    model = base_model(snapshot: snapshot_with([]))
    out = Hive::Tui::Views::Grid.render(model)
    assert_includes out, "(no projects registered; run `hive init <path>`)"
  end

  # ---- Project section ----

  def test_project_with_rows_shows_grouped_action_labels
    rows = [
      row(slug: "alpha", action_label: "ready to brainstorm", action_key: "ready_to_brainstorm"),
      row(slug: "beta", action_label: "ready to plan", action_key: "ready_to_plan")
    ]
    snap = snapshot_with([ project(name: "demo", rows: rows) ])
    model = base_model(snapshot: snap)
    out = Hive::Tui::Views::Grid.render(model)
    assert_includes out, "demo"
    assert_includes out, "ready to brainstorm"
    assert_includes out, "ready to plan"
    assert_includes out, "alpha"
    assert_includes out, "beta"
  end

  def test_project_with_zero_rows_shows_no_active_tasks
    snap = snapshot_with([ project(name: "demo", rows: []) ])
    model = base_model(snapshot: snap)
    out = Hive::Tui::Views::Grid.render(model)
    assert_includes out, "no active tasks"
  end

  def test_project_with_error_shows_error_string
    snap = snapshot_with([ project(name: "broken", rows: [], error: "missing_project_path") ])
    model = base_model(snapshot: snap)
    out = Hive::Tui::Views::Grid.render(model)
    assert_includes out, "error: missing_project_path"
  end

  # ---- Cursor highlight ----

  def test_cursor_indicator_marks_selected_row
    rows = [
      row(slug: "alpha", action_key: "ready_to_brainstorm", action_label: "ready to brainstorm"),
      row(slug: "beta",  action_key: "ready_to_brainstorm", action_label: "ready to brainstorm")
    ]
    snap = snapshot_with([ project(name: "demo", rows: rows) ])
    model = base_model(snapshot: snap, cursor: [ 0, 1 ])
    out = Hive::Tui::Views::Grid.render(model)
    # Cursor indicator '>' must appear before "beta", not before "alpha".
    beta_line = out.lines.find { |l| l.include?("beta") }
    alpha_line = out.lines.find { |l| l.include?("alpha") }
    assert_match(/>\s+beta/, beta_line, "cursor indicator must lead the selected row")
    refute_match(/>\s+alpha/, alpha_line, "non-cursor row must not show indicator")
  end

  # ---- Status line / flash ----

  def test_status_line_shows_help_hint_when_no_flash
    model = base_model(snapshot: snapshot_with([]))
    out = Hive::Tui::Views::Grid.render(model)
    assert_includes out, "[?] help"
    assert_includes out, "[/] filter"
    assert_includes out, "[q] quit"
  end

  def test_status_line_shows_flash_when_active
    fresh = Time.now - 1.0
    model = base_model(snapshot: snapshot_with([]), flash: "verb completed", flash_set_at: fresh)
    out = Hive::Tui::Views::Grid.render(model)
    assert_includes out, "verb completed"
    refute_includes out, "[?] help"
  end

  def test_status_line_falls_back_to_hint_when_flash_expired
    stale = Time.now - 30.0
    model = base_model(snapshot: snapshot_with([]), flash: "old", flash_set_at: stale)
    out = Hive::Tui::Views::Grid.render(model)
    assert_includes out, "[?] help"
    refute_includes out, "old"
  end

  # ---- Filter empty match ----

  def test_filter_with_zero_matches_shows_centered_message
    rows = [ row(slug: "alpha") ]
    snap = snapshot_with([ project(name: "demo", rows: rows) ])
    # Filter "auth" against single row "alpha" → zero matches.
    model = base_model(snapshot: snap, filter: "auth")
    out = Hive::Tui::Views::Grid.render(model)
    assert_includes out, %((no tasks matching "auth"))
  end

  # ---- Suggested command + age formatting ----

  def test_age_seconds_humanised
    rows = [
      row(slug: "a", age_seconds: 30,    action_label: "ready to plan", action_key: "ready_to_plan"),
      row(slug: "b", age_seconds: 90,    action_label: "ready to plan", action_key: "ready_to_plan"),
      row(slug: "c", age_seconds: 7200,  action_label: "ready to plan", action_key: "ready_to_plan"),
      row(slug: "d", age_seconds: 90_000, action_label: "ready to plan", action_key: "ready_to_plan")
    ]
    snap = snapshot_with([ project(name: "demo", rows: rows) ])
    model = base_model(snapshot: snap)
    out = Hive::Tui::Views::Grid.render(model)
    assert_match(/a\s.*\b30s\b/, out)
    assert_match(/b\s.*\b1m\b/, out)
    assert_match(/c\s.*\b2h\b/, out)
    assert_match(/d\s.*\b1d\b/, out)
  end

  def test_suggested_command_dash_when_nil
    rows = [ row(slug: "alpha", suggested_command: nil, action_label: "archived", action_key: "archived") ]
    snap = snapshot_with([ project(name: "demo", rows: rows) ])
    model = base_model(snapshot: snap)
    out = Hive::Tui::Views::Grid.render(model)
    assert_match(/alpha\s.*\barchived\b\s+-\s+\d/, out, "nil suggested_command must render as '-'")
  end

  # ---- Pure-function discipline ----

  def test_render_does_not_mutate_model
    snap = snapshot_with([ project(name: "demo", rows: [ row(slug: "a") ]) ])
    model = base_model(snapshot: snap, cursor: [ 0, 0 ])
    cursor_before = model.cursor
    Hive::Tui::Views::Grid.render(model)
    assert_equal cursor_before, model.cursor
  end
end
