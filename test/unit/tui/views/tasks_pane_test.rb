require "test_helper"
require "hive/tui/model"
require "hive/tui/snapshot"
require "hive/tui/views/tasks_pane"

# Hive::Tui::Views::TasksPane is the right pane of the v2 two-pane
# layout. These tests pin layout/text content via assert_includes and
# verify the focus-driven border distinction by border_for(model)
# identity (lipgloss strips ANSI in non-tty test environments).
class HiveTuiViewsTasksPaneTest < Minitest::Test
  include HiveTestHelper

  def make_task(slug:, stage: "2-brainstorm", action: "ready_to_plan",
                action_label: "Ready to plan", age: 120,
                marker: "complete", suggested: "hive plan #{slug} --from 2-brainstorm")
    {
      "slug" => slug,
      "stage" => stage,
      "folder" => "/tmp/#{slug}",
      "state_file" => "/tmp/#{slug}/brainstorm.md",
      "marker" => marker,
      "attrs" => {},
      "mtime" => "2026-05-01T00:00:00Z",
      "age_seconds" => age,
      "claude_pid" => nil,
      "claude_pid_alive" => nil,
      "action" => action,
      "action_label" => action_label,
      "suggested_command" => suggested
    }
  end

  def make_snapshot(projects)
    Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-01T00:00:00Z",
      "projects" => projects
    )
  end

  def make_model(snapshot:, scope: 0, pane_focus: :right, cursor: [ 0, 0 ], filter: nil)
    Hive::Tui::Model.initial.with(snapshot: snapshot, scope: scope,
                                  pane_focus: pane_focus, cursor: cursor,
                                  filter: filter)
  end

  # ---- Title / scope ----

  def test_title_says_all_projects_when_scope_zero
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [ make_task(slug: "abc-001") ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap, scope: 0), width: 80)
    assert_includes out, "Tasks · ★ All projects"
  end

  def test_title_says_project_name_when_scope_n
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [ make_task(slug: "abc-001") ] },
      { "name" => "seyarabata", "tasks" => [ make_task(slug: "xyz-002") ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap, scope: 2), width: 80)
    assert_includes out, "Tasks · seyarabata"
  end

  # ---- Column rendering ----

  def test_renders_5_columns_per_row
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [ make_task(slug: "abc-001", stage: "3-plan", action_label: "Needs your input", age: 90) ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    assert_includes out, "abc-001",          "slug column must render"
    assert_includes out, "3-plan",           "stage column must render"
    assert_includes out, "Needs your input", "status column must render"
    assert_includes out, "1m",               "age column must render (90s → 1m)"
  end

  def test_action_keys_pick_distinct_icons
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(slug: "running-task", action: "agent_running", action_label: "Agent running"),
        make_task(slug: "ready-task", action: "ready_to_plan", action_label: "Ready to plan"),
        make_task(slug: "error-task", action: "error", action_label: "Error")
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    assert_includes out, "🤖", "agent_running rows must show robot icon"
    assert_includes out, "▶",  "ready_* rows must show advance arrow"
    assert_includes out, "⚠",  "error rows must show warning icon"
  end

  # ---- Sort order ----

  def test_rows_sorted_by_action_label_order
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(slug: "zzz-late",  action: "agent_running", action_label: "Agent running"),
        make_task(slug: "aaa-early", action: "ready_to_plan", action_label: "Ready to plan")
      ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 100)
    early_idx = out.index("aaa-early")
    late_idx = out.index("zzz-late")
    refute_nil early_idx
    refute_nil late_idx
    assert_operator early_idx, :<, late_idx,
                    "Ready-to-plan rows must precede Agent-running rows per ACTION_LABEL_ORDER"
  end

  # ---- Cursor highlight ----

  def test_cursor_highlight_only_applies_when_pane_focus_right
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [
        make_task(slug: "row-zero", action: "ready_to_plan", action_label: "Ready to plan")
      ] }
    ])
    # Render twice — once with right focus, once with left — and assert
    # both produce text containing the slug. The actual reverse-video
    # styling is ANSI-stripped under non-tty.
    out_right = Hive::Tui::Views::TasksPane.render(
      make_model(snapshot: snap, pane_focus: :right, cursor: [ 0, 0 ]), width: 80
    )
    out_left = Hive::Tui::Views::TasksPane.render(
      make_model(snapshot: snap, pane_focus: :left, cursor: [ 0, 0 ]), width: 80
    )
    assert_includes out_right, "row-zero"
    assert_includes out_left, "row-zero"
  end

  # ---- Border focus state ----

  def test_uses_focused_border_when_pane_focus_right
    snap = make_snapshot([])
    chosen = Hive::Tui::Views::TasksPane.border_for(make_model(snapshot: snap, pane_focus: :right))
    assert_same Hive::Tui::Styles::PANE_FOCUSED_BORDER, chosen
  end

  def test_uses_dim_border_when_pane_focus_left
    snap = make_snapshot([])
    chosen = Hive::Tui::Views::TasksPane.border_for(make_model(snapshot: snap, pane_focus: :left))
    assert_same Hive::Tui::Styles::PANE_DIM_BORDER, chosen
  end

  # ---- Edge / error cases ----

  def test_nil_snapshot_renders_loading_placeholder
    model = Hive::Tui::Model.initial.with(snapshot: nil, pane_focus: :right)
    out = Hive::Tui::Views::TasksPane.render(model, width: 80)
    assert_includes out, "loading", "nil snapshot must surface a loading hint, not crash"
  end

  def test_empty_visible_rows_renders_no_tasks_placeholder
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [ make_task(slug: "real-task") ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(
      make_model(snapshot: snap, filter: "definitely-not-matching"), width: 80
    )
    assert_includes out, "no tasks"
  end

  def test_long_slug_is_truncated_with_ellipsis
    long_slug = "this-is-a-very-long-slug-that-overflows-the-column"
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [ make_task(slug: long_slug) ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 80)
    refute_includes out, long_slug, "long slug must be truncated"
    assert_includes out, "…"
  end

  def test_narrow_width_does_not_crash
    snap = make_snapshot([
      { "name" => "hive", "tasks" => [ make_task(slug: "x") ] }
    ])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 50)
    refute_nil out
    assert out.is_a?(String)
  end

  def test_snapshot_with_zero_projects_renders_no_tasks_placeholder
    snap = make_snapshot([])
    out = Hive::Tui::Views::TasksPane.render(make_model(snapshot: snap), width: 80)
    assert_includes out, "no tasks"
  end

  # ---- Format.age helper ----

  def test_format_age_handles_seconds
    assert_equal "30s", Hive::Tui::Views::Format.age(30)
  end

  def test_format_age_handles_minutes
    assert_equal "5m", Hive::Tui::Views::Format.age(300)
  end

  def test_format_age_handles_hours
    assert_equal "2h", Hive::Tui::Views::Format.age(7200)
  end

  def test_format_age_handles_days
    assert_equal "3d", Hive::Tui::Views::Format.age(259_200)
  end
end
