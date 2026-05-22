require "test_helper"
require "hive/tui/model"
require "hive/tui/snapshot"
require "hive/tui/views/new_idea_project_picker"

class HiveTuiViewsNewIdeaProjectPickerTest < Minitest::Test
  include HiveTestHelper

  def snapshot
    Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-17T00:00:00Z",
      "projects" => [
        { "name" => "broken", "error" => "missing_project_path", "tasks" => [] },
        { "name" => "hive", "tasks" => [] },
        { "name" => "writero", "tasks" => [] }
      ]
    )
  end

  def test_render_lists_healthy_projects_and_highlights_cursor
    model = Hive::Tui::Model.initial.with(
      mode: :new_idea_project,
      snapshot: snapshot,
      new_idea_project_cursor: 1
    )

    out = Hive::Tui::Views::NewIdeaProjectPicker.render(model, width: 80)

    assert_includes out, "Choose project for new idea:"
    assert_includes out, "hive"
    assert_includes out, "> writero"
    refute_includes out, "broken"
  end

  def test_choices_skip_unhealthy_projects
    model = Hive::Tui::Model.initial.with(snapshot: snapshot)

    assert_equal %w[hive writero],
      Hive::Tui::Views::NewIdeaProjectPicker.choices(model).map(&:name)
  end

  def test_empty_choices_render_clear_message
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-17T00:00:00Z",
      "projects" => [ { "name" => "broken", "error" => "missing_project_path", "tasks" => [] } ]
    )
    model = Hive::Tui::Model.initial.with(mode: :new_idea_project, snapshot: snap)

    assert_includes Hive::Tui::Views::NewIdeaProjectPicker.render(model), "No healthy projects"
  end

  def test_nil_snapshot_renders_loading_message
    model = Hive::Tui::Model.initial.with(mode: :new_idea_project, snapshot: nil)

    assert_includes Hive::Tui::Views::NewIdeaProjectPicker.render(model), "Loading projects"
  end

  def test_choices_returns_empty_when_snapshot_is_nil
    model = Hive::Tui::Model.initial.with(snapshot: nil)

    assert_empty Hive::Tui::Views::NewIdeaProjectPicker.choices(model)
  end

  def test_visible_projects_windows_long_lists_around_cursor
    projects = 8.times.map { |idx| Struct.new(:name).new("project-#{idx + 1}") }

    visible, first_idx = Hive::Tui::Views::NewIdeaProjectPicker.visible_projects(projects, 7)

    assert_equal 2, first_idx
    assert_equal %w[project-3 project-4 project-5 project-6 project-7 project-8], visible.map(&:name)
  end

  def test_truncate_leaves_line_unchanged_when_width_is_not_positive
    line = "Choose project for new idea: hive"

    assert_equal line, Hive::Tui::Views::NewIdeaProjectPicker.truncate(line, 0)
    assert_equal line, Hive::Tui::Views::NewIdeaProjectPicker.truncate(line, -5)
  end
end
