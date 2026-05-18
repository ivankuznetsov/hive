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
end
