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

  def test_choices_exclude_duplicate_names_regardless_of_health
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-08-30T00:00:00Z",
      "projects" => [
        { "name" => "both-healthy", "tasks" => [] },
        { "name" => "both-healthy", "tasks" => [] },
        { "name" => "mixed", "tasks" => [] },
        { "name" => "mixed", "error" => "not_initialised", "tasks" => [] },
        { "name" => "alpha", "tasks" => [] }
      ]
    )
    model = Hive::Tui::Model.initial.with(snapshot: snap)

    assert_equal [ "alpha" ],
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

  def test_ambiguity_only_picker_names_duplicate_and_recovery_action
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-08-30T00:00:00Z",
      "projects" => [
        { "name" => "duplicate", "tasks" => [] },
        { "name" => "duplicate", "error" => "not_initialised", "tasks" => [] }
      ]
    )
    model = Hive::Tui::Model.initial.with(mode: :new_idea_project, snapshot: snap)

    out = Hive::Tui::Views::NewIdeaProjectPicker.render(model)

    assert_match(/duplicate project name.*"duplicate"/i, out)
    assert_match(/hive forget|disambiguate/i, out)
    refute_match(/no healthy projects/i, out)
  end

  def test_empty_registry_is_distinct_from_unhealthy_projects
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-08-30T00:00:00Z",
      "projects" => []
    )
    model = Hive::Tui::Model.initial.with(mode: :new_idea_project, snapshot: snap)

    out = Hive::Tui::Views::NewIdeaProjectPicker.render(model)

    assert_match(/no projects registered/i, out)
    refute_match(/no healthy projects/i, out)
  end

  def test_empty_message_has_a_safe_fallback_for_nonempty_authority_states
    admission = Hive::Tui::Snapshot::NewIdeaAdmission.new(
      state: :available,
      projects: []
    )

    assert_equal "No selectable projects available",
      Hive::Tui::Views::NewIdeaProjectPicker.empty_message(admission)
  end

  def test_nil_cursor_renders_admissible_rows_without_a_highlight
    model = Hive::Tui::Model.initial.with(
      mode: :new_idea_project,
      snapshot: snapshot,
      new_idea_project_cursor: nil
    )

    out = Hive::Tui::Views::NewIdeaProjectPicker.render(model, width: 80)

    assert_includes out, "  hive"
    assert_includes out, "  writero"
    refute_match(/^> /, out)
    assert_match(/j\/k select/i, out)
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

  # Regression: with a populated snapshot and a project name whose cursor
  # row exceeds the terminal width, every rendered row must stay within
  # its visible cell budget. Truncation runs after styling in render(),
  # so it has to measure escape bytes as zero-width cells rather than
  # counting them as visible output.
  def test_render_rows_fit_visible_width_when_project_name_overflows
    snap = Hive::Tui::Snapshot.from_payload(
      "generated_at" => "2026-05-17T00:00:00Z",
      "projects" => [
        { "name" => "a-very-long-project-name-that-overflows-narrow-views", "tasks" => [] }
      ]
    )
    model = Hive::Tui::Model.initial.with(
      mode: :new_idea_project,
      snapshot: snap,
      new_idea_project_cursor: 0
    )

    out = Hive::Tui::Views::NewIdeaProjectPicker.render(model, width: 30)

    out.each_line(chomp: true).each do |line|
      assert_operator Hive::Tui::Views::Format.display_width(line), :<=, 30,
        "row #{line.inspect} exceeds the render width"
    end
    assert_includes out, "a-very-long-pro", "visible prefix must survive the cut"
  end

  def test_truncate_leaves_line_unchanged_when_width_is_not_positive
    line = "Choose project for new idea: hive"

    assert_equal line, Hive::Tui::Views::NewIdeaProjectPicker.truncate(line, 0)
    assert_equal line, Hive::Tui::Views::NewIdeaProjectPicker.truncate(line, -5)
  end

  # Regression: the cursor row is styled (reverse video) before the final
  # `rows.map { truncate(line, width) }` pass, so truncation has to handle
  # a line that already contains ANSI escapes — measuring only its visible
  # cells and keeping the trailing reset intact. Hand-rolled SGR escapes
  # stand in for Styles::CURSOR_HIGHLIGHT.render, which Lipgloss strips in
  # non-tty test environments.
  def test_truncate_keeps_styled_cursor_row_within_width_and_reset_intact
    styled = "\e[7m> #{'hive-project-' * 5}\e[0m"

    out = Hive::Tui::Views::NewIdeaProjectPicker.truncate(styled, 30)

    assert_equal 30, Hive::Tui::Views::Format.display_width(out)
    assert out.end_with?("…"), "expected ellipsis after truncation"
    assert_includes out, "\e[0m",
      "truncation must not slice off the style's reset sequence"
    assert_includes out, "> hive-pro", "visible prefix must survive the cut"
  end
end
