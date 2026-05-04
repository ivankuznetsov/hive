require "test_helper"
require "hive/tui/model"
require "hive/tui/snapshot"
require "hive/tui/views/projects_pane"

# Hive::Tui::Views::ProjectsPane is the left pane of the v2 two-pane
# layout. These tests pin layout/text content via assert_includes and
# verify the focus-driven border distinction without ANSI assertions
# (lipgloss-ruby strips ANSI in non-tty environments).
class HiveTuiViewsProjectsPaneTest < Minitest::Test
  include HiveTestHelper

  PROJECT_NAMES = %w[hive seyarabata appcrawl].freeze

  def make_snapshot(names: PROJECT_NAMES)
    Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01T00:00:00Z",
      "projects" => names.map { |n| { "name" => n, "tasks" => [] } }
    )
  end

  def make_model(scope: 0, pane_focus: :left, snapshot: make_snapshot)
    Hive::Tui::Model.initial.with(snapshot: snapshot, scope: scope, pane_focus: pane_focus)
  end

  # ---- Layout / content ----

  def test_renders_all_projects_virtual_entry
    out = Hive::Tui::Views::ProjectsPane.render(make_model, width: 30)
    assert_includes out, "★ All projects",
                    "left pane must always include the virtual ★ entry"
  end

  def test_renders_each_registered_project_name
    out = Hive::Tui::Views::ProjectsPane.render(make_model, width: 30)
    PROJECT_NAMES.each do |name|
      assert_includes out, name, "registered project #{name.inspect} must appear in the pane"
    end
  end

  def test_renders_projects_in_registry_order
    out = Hive::Tui::Views::ProjectsPane.render(make_model, width: 30)
    indices = PROJECT_NAMES.map { |name| out.index(name) }
    assert_equal indices, indices.sort,
                 "projects must appear in registry order, not sorted/shuffled"
  end

  def test_renders_projects_pane_title
    out = Hive::Tui::Views::ProjectsPane.render(make_model, width: 30)
    assert_includes out, "Projects", "pane should carry a 'Projects' title header"
  end

  # ---- Selection (cursor highlight) ----
  # Verifies the selection predicate directly. lipgloss strips ANSI in
  # non-tty so render output cannot distinguish selected vs unselected
  # rows by visual styling — the boolean decision is what unit tests
  # can pin. Visual confirmation is via tty dogfood + e2e asciinema.
  # Same pattern as TasksPane#highlight?.

  def test_selected_predicate_marks_all_projects_row_when_scope_zero
    model = make_model(scope: 0)
    assert Hive::Tui::Views::ProjectsPane.selected?(model, 0),
           "scope=0 must select the ★ All projects virtual row"
    refute Hive::Tui::Views::ProjectsPane.selected?(model, 1),
           "scope=0 must NOT select the first registered project"
  end

  def test_selected_predicate_marks_nth_project_when_scope_n
    model = make_model(scope: 2)
    refute Hive::Tui::Views::ProjectsPane.selected?(model, 0),
           "scope=2 must NOT select the ★ All projects row"
    refute Hive::Tui::Views::ProjectsPane.selected?(model, 1),
           "scope=2 must NOT select the first registered project"
    assert Hive::Tui::Views::ProjectsPane.selected?(model, 2),
           "scope=2 must select the second registered project"
  end

  def test_renders_all_rows_regardless_of_selection
    # Non-selection-specific render assertion: every row appears in
    # the output. Kept as a smoke check; the selection-specific
    # behavior is covered by the predicate tests above.
    out = Hive::Tui::Views::ProjectsPane.render(make_model(scope: 0), width: 30)
    assert_includes out, "★ All projects"
    PROJECT_NAMES.each { |name| assert_includes out, name }
  end

  # ---- Focus state ----

  def test_uses_focused_border_when_pane_focus_left
    chosen = Hive::Tui::Views::ProjectsPane.border_for(make_model(pane_focus: :left))
    assert_same Hive::Tui::Styles::PANE_FOCUSED_BORDER, chosen,
                ":left pane_focus must select the focused border constant"
  end

  def test_uses_dim_border_when_pane_focus_right
    chosen = Hive::Tui::Views::ProjectsPane.border_for(make_model(pane_focus: :right))
    assert_same Hive::Tui::Styles::PANE_DIM_BORDER, chosen,
                ":right pane_focus must select the dim border constant"
  end

  # ---- Edge cases ----

  def test_empty_snapshot_renders_placeholder_without_raising
    model = Hive::Tui::Model.initial.with(snapshot: nil, pane_focus: :left)
    out = Hive::Tui::Views::ProjectsPane.render(model, width: 30)
    assert_includes out, "★ All projects"
    assert_includes out, "hive init", "empty-snapshot placeholder must hint at the next step"
  end

  def test_snapshot_with_zero_projects_renders_placeholder
    model = Hive::Tui::Model.initial.with(snapshot: make_snapshot(names: []), pane_focus: :left)
    out = Hive::Tui::Views::ProjectsPane.render(model, width: 30)
    assert_includes out, "★ All projects"
    assert_includes out, "hive init"
  end

  def test_scope_beyond_projects_size_does_not_raise
    # Defensive: a scope value greater than projects.size should not crash.
    # No project gets the highlight; the pane still renders cleanly.
    model = make_model(scope: 99)
    out = Hive::Tui::Views::ProjectsPane.render(model, width: 30)
    assert_includes out, "★ All projects"
    assert_includes out, "hive"
  end

  # ---- Unhealthy-project label decoration ----

  def test_unhealthy_project_renders_with_warning_marker
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-04",
      "projects" => [
        { "name" => "hive", "tasks" => [] },
        { "name" => "demo", "error" => "missing_project_path", "tasks" => [] }
      ]
    )
    model = Hive::Tui::Model.initial.with(snapshot: snap, scope: 0, pane_focus: :left)
    out = Hive::Tui::Views::ProjectsPane.render(model, width: 40)
    assert_includes out, "⚠ demo (missing)",
                    "broken project must surface the error short-name so operator sees it at a glance"
    refute_match(/⚠ hive/, out, "healthy project must NOT carry the warning marker")
  end

  def test_unhealthy_project_with_not_initialised_error
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-04",
      "projects" => [
        { "name" => "stale", "error" => "not_initialised", "tasks" => [] }
      ]
    )
    model = Hive::Tui::Model.initial.with(snapshot: snap, scope: 0, pane_focus: :left)
    out = Hive::Tui::Views::ProjectsPane.render(model, width: 40)
    assert_includes out, "⚠ stale (needs init)"
  end

  def test_long_project_name_is_truncated_with_ellipsis
    long_name = "this-is-a-very-long-project-name-that-overflows"
    model = Hive::Tui::Model.initial.with(snapshot: make_snapshot(names: [ long_name ]),
                                          pane_focus: :left)
    out = Hive::Tui::Views::ProjectsPane.render(model, width: 20)
    refute_includes out, long_name, "long names must not overflow the pane width"
    assert_includes out, "…", "truncated names should carry an ellipsis"
  end

  def test_narrow_width_does_not_crash
    # Defensive: width = 3 (border + 1 inner cell). Should still render.
    model = make_model
    out = Hive::Tui::Views::ProjectsPane.render(model, width: 3)
    refute_nil out
    assert out.is_a?(String)
  end
end
